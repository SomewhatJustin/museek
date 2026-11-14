package museek

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Links are collection-scoped bearer invitations, stored only as hashes. Their
// issuer must still have an active device and a grant when the link is redeemed.
func (a *API) sharePlaylist(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	session := sessionFromContext(r.Context())
	token, err := randomToken(32)
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	expires := time.Now().Add(24 * time.Hour)
	result, err := a.store.db.ExecContext(r.Context(), `INSERT INTO playlist_links (token_hash,collection_id,session_id,expires_at)
SELECT ?,g.collection_id,?,? FROM grants g WHERE g.recipient_id=? AND g.collection_id=?`,
		hashSecret(token), session.ID, expires.Unix(), session.RecipientID, r.PathValue("id"))
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	if n, _ := result.RowsAffected(); n == 0 {
		writeError(w, 404, "playlist not found")
		return
	}
	link := a.baseURL(r) + "/invite#" + url.Values{"playlist": {token}}.Encode()
	writeJSON(w, 201, map[string]any{"url": link, "expiresAt": expires})
}

func (a *API) redeemPlaylistLink(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !a.pairLimits.Allow("playlist:"+requestIP(r), time.Now()) {
		w.Header().Set("Retry-After", "300")
		writeError(w, 429, "too many invitation attempts")
		return
	}
	var input struct {
		Token      string `json:"token"`
		DeviceName string `json:"deviceName"`
	}
	if err := decodeJSON(r, &input); err != nil || len(input.Token) != 43 || len(input.DeviceName) > 200 {
		writeError(w, 400, "invalid playlist invitation")
		return
	}
	var recipientID string
	if header := r.Header.Get("Authorization"); header != "" {
		if !strings.HasPrefix(header, "Bearer ") {
			writeError(w, 401, "device session is required")
			return
		}
		session, err := a.store.Authenticate(r.Context(), strings.TrimPrefix(header, "Bearer "))
		if err != nil {
			writeError(w, 401, "device session is invalid or revoked")
			return
		}
		recipientID = session.RecipientID
	}
	collectionID, pair, err := a.store.redeemPlaylist(r.Context(), input.Token, recipientID, input.DeviceName)
	if errors.Is(err, ErrCodeInvalid) {
		writeError(w, 404, "This playlist link is invalid or expired.")
		return
	}
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	writeJSON(w, 200, struct {
		CollectionID string      `json:"collectionId"`
		Session      *PairResult `json:"session,omitempty"`
	}{collectionID, pair})
}

func (s *Store) redeemPlaylist(ctx context.Context, token, recipientID, deviceName string) (string, *PairResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", nil, err
	}
	defer tx.Rollback()
	var collectionID string
	err = tx.QueryRowContext(ctx, `SELECT l.collection_id FROM playlist_links l
JOIN device_sessions d ON d.id=l.session_id AND d.revoked_at IS NULL
JOIN grants g ON g.recipient_id=d.recipient_id AND g.collection_id=l.collection_id
WHERE l.token_hash=? AND l.expires_at>?`, hashSecret(token), nowUnix()).Scan(&collectionID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil, ErrCodeInvalid
	}
	if err != nil {
		return "", nil, err
	}
	var pair *PairResult
	if recipientID == "" {
		recipientID = randomID()
		name := "Playlist listener " + recipientID
		if _, err := tx.ExecContext(ctx, `INSERT INTO recipients (id,name,created_at) VALUES (?,?,?)`, recipientID, name, nowUnix()); err != nil {
			return "", nil, err
		}
		sessionToken, err := randomToken(32)
		if err != nil {
			return "", nil, err
		}
		if strings.TrimSpace(deviceName) == "" {
			deviceName = "iPhone"
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO device_sessions (id,token_hash,recipient_id,device_name,created_at,last_used_at) VALUES (?,?,?,?,?,?)`, randomID(), hashSecret(sessionToken), recipientID, deviceName, nowUnix(), nowUnix()); err != nil {
			return "", nil, err
		}
		pair = &PairResult{Token: sessionToken}
		pair.Recipient.ID = recipientID
		pair.Recipient.Name = name
	}
	if _, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO grants (recipient_id,collection_id,created_at) VALUES (?,?,?)`, recipientID, collectionID, nowUnix()); err != nil {
		return "", nil, err
	}
	if err := tx.Commit(); err != nil {
		return "", nil, err
	}
	return collectionID, pair, nil
}
