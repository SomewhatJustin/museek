package museek

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type API struct {
	store      *Store
	signer     *StreamSigner
	musicRoot  string
	publicURL  string
	logger     *slog.Logger
	pairLimits *pairRateLimiter
}

type sessionContextKey struct{}

func NewAPI(store *Store, signer *StreamSigner, musicRoot, publicURL string, logger *slog.Logger) (*API, error) {
	root, err := filepath.Abs(musicRoot)
	if err != nil {
		return nil, err
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return nil, fmt.Errorf("resolve music directory: %w", err)
	}
	if publicURL != "" {
		parsed, err := url.Parse(publicURL)
		if err != nil || parsed.Scheme == "" || parsed.Host == "" {
			return nil, errors.New("public URL must be an absolute HTTP(S) URL")
		}
		publicURL = strings.TrimRight(publicURL, "/")
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &API{
		store:      store,
		signer:     signer,
		musicRoot:  root,
		publicURL:  publicURL,
		logger:     logger,
		pairLimits: newPairRateLimiter(5, 5*time.Minute),
	}, nil
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.health)
	mux.HandleFunc("GET /invite", a.inviteLanding)
	mux.HandleFunc("POST /v1/pair", a.pair)
	mux.Handle("GET /v1/collections", a.requireSession(http.HandlerFunc(a.listCollections)))
	mux.Handle("GET /v1/collections/{id}", a.requireSession(http.HandlerFunc(a.collectionDetail)))
	mux.Handle("POST /v1/tracks/{id}/play-url", a.requireSession(http.HandlerFunc(a.playURL)))
	mux.HandleFunc("GET /v1/streams/{id}", a.stream)
	mux.Handle("GET /v1/artwork/{id}", a.requireSession(http.HandlerFunc(a.artwork)))
	return a.recoverAndLog(mux)
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	if err := a.store.db.PingContext(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *API) pair(w http.ResponseWriter, r *http.Request) {
	clientIP := requestIP(r)
	if !a.pairLimits.Allow(clientIP, time.Now()) {
		w.Header().Set("Retry-After", "300")
		writeError(w, http.StatusTooManyRequests, "too many pairing attempts")
		return
	}
	var input struct {
		Code       string `json:"code"`
		DeviceName string `json:"deviceName"`
	}
	if err := decodeJSON(r, &input); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	result, err := a.store.Pair(r.Context(), input.Code, input.DeviceName)
	if errors.Is(err, ErrCodeInvalid) {
		writeError(w, http.StatusUnauthorized, "pairing code is invalid or expired")
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, result)
}

func (a *API) listCollections(w http.ResponseWriter, r *http.Request) {
	session := sessionFromContext(r.Context())
	items, err := a.store.ListCollections(r.Context(), session.RecipientID)
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"collections": items})
}

func (a *API) collectionDetail(w http.ResponseWriter, r *http.Request) {
	session := sessionFromContext(r.Context())
	item, err := a.store.CollectionDetail(r.Context(), session.RecipientID, r.PathValue("id"))
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "collection not found")
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, item)
}

func (a *API) playURL(w http.ResponseWriter, r *http.Request) {
	session := sessionFromContext(r.Context())
	track, err := a.store.TrackForRecipient(r.Context(), session.RecipientID, r.PathValue("id"))
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "track not found")
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	expires := time.Now().UTC().Add(time.Hour)
	token, err := a.signer.Sign(track.ID, session.ID, expires)
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	result := PlayURL{
		URL:       fmt.Sprintf("%s/v1/streams/%s?token=%s", a.baseURL(r), url.PathEscape(track.ID), url.QueryEscape(token)),
		ExpiresAt: expires,
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *API) stream(w http.ResponseWriter, r *http.Request) {
	claims, err := a.signer.Verify(r.URL.Query().Get("token"), time.Now())
	if err != nil || claims.TrackID != r.PathValue("id") {
		writeError(w, http.StatusUnauthorized, "stream authorization is invalid or expired")
		return
	}
	session, err := a.store.ActiveSessionByID(r.Context(), claims.SessionID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "device session is revoked")
		return
	}
	track, err := a.store.TrackForRecipient(r.Context(), session.RecipientID, claims.TrackID)
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "track not found")
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	root := a.musicRoot
	if track.Storage == "data" {
		root = a.store.dataDir
	}
	path, err := safeFilePath(root, track.RelativePath)
	if errors.Is(err, os.ErrNotExist) {
		writeError(w, http.StatusNotFound, "track file not found")
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		writeError(w, http.StatusNotFound, "track file not found")
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "audio/mpeg")
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, track.Title+".mp3", info.ModTime(), file)
}

func (a *API) artwork(w http.ResponseWriter, r *http.Request) {
	session := sessionFromContext(r.Context())
	path, contentType, err := a.store.ArtworkForRecipient(r.Context(), session.RecipientID, r.PathValue("id"))
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "artwork not found")
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		writeError(w, http.StatusNotFound, "artwork not found")
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, "artwork", info.ModTime(), file)
}

func (a *API) requireSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(header, prefix) {
			writeError(w, http.StatusUnauthorized, "device session is required")
			return
		}
		session, err := a.store.Authenticate(r.Context(), strings.TrimSpace(strings.TrimPrefix(header, prefix)))
		if err != nil {
			writeError(w, http.StatusUnauthorized, "device session is invalid or revoked")
			return
		}
		ctx := context.WithValue(r.Context(), sessionContextKey{}, session)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func sessionFromContext(ctx context.Context) Session {
	session, _ := ctx.Value(sessionContextKey{}).(Session)
	return session
}

func (a *API) safeMusicPath(relative string) (string, error) {
	return safeFilePath(a.musicRoot, relative)
}

func safeFilePath(root, relative string) (string, error) {
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	if filepath.IsAbs(relative) {
		return "", errors.New("absolute music path rejected")
	}
	candidate := filepath.Join(root, filepath.FromSlash(relative))
	resolved, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(root, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("music path escapes configured root")
	}
	return resolved, nil
}

func (a *API) baseURL(r *http.Request) string {
	if a.publicURL != "" {
		return a.publicURL
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	if forwarded := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0]); forwarded == "http" || forwarded == "https" {
		scheme = forwarded
	}
	return scheme + "://" + r.Host
}

func (a *API) internalError(w http.ResponseWriter, r *http.Request, err error) {
	a.logger.Error("request failed", "method", r.Method, "path", r.URL.Path, "error", err)
	writeError(w, http.StatusInternalServerError, "internal server error")
}

func (a *API) recoverAndLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		status := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		defer func() {
			if recovered := recover(); recovered != nil {
				a.logger.Error("panic serving request", "method", r.Method, "path", r.URL.Path, "panic", recovered)
				if !status.wroteHeader {
					writeError(status, http.StatusInternalServerError, "internal server error")
				}
			}
			a.logger.Info("request", "method", r.Method, "path", r.URL.Path, "status", status.status, "duration", time.Since(started))
		}()
		next.ServeHTTP(status, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.wroteHeader = true
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Write(data []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(data)
}

func decodeJSON(r *http.Request, target any) error {
	defer r.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(r.Body, 8<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return errors.New("invalid JSON request")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("request must contain one JSON object")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func requestIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

type pairRateLimiter struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	hits   map[string][]time.Time
}

func newPairRateLimiter(limit int, window time.Duration) *pairRateLimiter {
	return &pairRateLimiter{limit: limit, window: window, hits: make(map[string][]time.Time)}
}

func (l *pairRateLimiter) Allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	cutoff := now.Add(-l.window)
	prior := l.hits[key]
	kept := prior[:0]
	for _, hit := range prior {
		if hit.After(cutoff) {
			kept = append(kept, hit)
		}
	}
	if len(kept) >= l.limit {
		l.hits[key] = kept
		return false
	}
	l.hits[key] = append(kept, now)
	return true
}
