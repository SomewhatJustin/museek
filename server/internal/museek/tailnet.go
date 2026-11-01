package museek

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"
)

// TailnetHandler must only be exposed behind the local Tailscale Serve proxy.
// Never mount this on the public listener: headers alone do not prove provenance.
func (a *API) TailnetHandler(raw string) (http.Handler, error) {
	decoder := json.NewDecoder(strings.NewReader(raw))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, errors.New("tailnet users must be a JSON object")
	}
	users := map[string]string{}
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		login, ok := key.(string)
		if !ok || login == "" || strings.TrimSpace(login) != login || strings.ContainsAny(login, ",\r\n") {
			return nil, errors.New("invalid tailnet login")
		}
		if _, exists := users[login]; exists {
			return nil, errors.New("duplicate tailnet login")
		}
		var name string
		if err := decoder.Decode(&name); err != nil {
			return nil, err
		}
		var id string
		if err := a.store.db.QueryRowContext(context.Background(), `SELECT id FROM recipients WHERE name = ? COLLATE BINARY`, name).Scan(&id); err != nil {
			return nil, errors.New("tailnet mapping must reference an existing exact recipient name")
		}
		users[login] = id
	}
	if _, err := decoder.Token(); err != nil {
		return nil, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF || len(users) == 0 {
		return nil, errors.New("invalid or empty tailnet mapping")
	}
	limits := newPairRateLimiter(5, 5*time.Minute)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/server", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"name": "Museek", "tailnetJoin": true, "version": 1})
	})
	mux.HandleFunc("POST /v1/tailnet/join", func(w http.ResponseWriter, r *http.Request) {
		login := r.Header.Get("Tailscale-User-Login")
		if !limits.Allow(login, time.Now()) {
			w.Header().Set("Retry-After", "300")
			writeError(w, 429, "too many join attempts")
			return
		}
		var input struct {
			DeviceName string `json:"deviceName"`
		}
		if err := decodeJSON(r, &input); err != nil || len(input.DeviceName) > 200 {
			writeError(w, 400, "invalid join request")
			return
		}
		result, err := a.store.tailnetSession(r.Context(), users[login], input.DeviceName)
		if err != nil {
			a.internalError(w, r, err)
			return
		}
		writeJSON(w, 201, result)
	})
	mux.Handle("/", a.Handler())
	return a.recoverAndLog(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.URL.Path == "/v1/server" || r.URL.Path == "/v1/tailnet/join" {
			values := r.Header.Values("Tailscale-User-Login")
			_, funnel := r.Header[http.CanonicalHeaderKey("Ts-Funnel-Request")]
			if funnel || len(values) != 1 || users[values[0]] == "" {
				writeError(w, 403, "This Tailscale account is not authorized to join Museek.")
				return
			}
		}
		mux.ServeHTTP(w, r)
	})), nil
}

func (s *Store) tailnetSession(ctx context.Context, recipientID, deviceName string) (PairResult, error) {
	var result PairResult
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()
	result.Recipient.ID = recipientID
	if err := tx.QueryRowContext(ctx, `SELECT name FROM recipients WHERE id = ?`, recipientID).Scan(&result.Recipient.Name); err != nil {
		return result, err
	}
	token, err := randomToken(32)
	if err != nil {
		return result, err
	}
	if strings.TrimSpace(deviceName) == "" {
		deviceName = "iPhone"
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO device_sessions (id,token_hash,recipient_id,device_name,created_at,last_used_at) VALUES (?,?,?,?,?,?)`, randomID(), hashSecret(token), recipientID, deviceName, nowUnix(), nowUnix())
	if err != nil {
		return result, err
	}
	result.Token = token
	return result, tx.Commit()
}
