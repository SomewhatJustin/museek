package museek

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"regexp"
)

var ErrListenInput = errors.New("invalid listen")
var listenIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

type Listen struct {
	ID         string `json:"id"`
	TrackID    string `json:"trackId"`
	Client     string `json:"client"`
	ListenedMS int64  `json:"listenedMs"`
}

func (s *Store) migrateAnalytics(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS track_listens (
 id TEXT PRIMARY KEY,
 collection_id TEXT NOT NULL,
 track_id TEXT NOT NULL,
 recipient_id TEXT NOT NULL REFERENCES recipients(id) ON DELETE CASCADE,
 listened_ms INTEGER NOT NULL CHECK(listened_ms > 30000),
 client TEXT NOT NULL CHECK(client = 'iphone'),
 received_at INTEGER NOT NULL,
 FOREIGN KEY(collection_id, track_id) REFERENCES playlist_entries(collection_id, track_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS track_listens_entry_idx ON track_listens(collection_id, track_id);
`)
	return err
}

// Stream requests and downloads never create listens. Only the iPhone playback
// reporter submits these events; the source and playback time are client-reported.
func (s *Store) RecordListen(ctx context.Context, session Session, cid string, listen Listen) error {
	if !listenIDPattern.MatchString(listen.ID) || listen.TrackID == "" || listen.Client != "iphone" || listen.ListenedMS <= 30000 {
		return ErrListenInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var allowed int
	err = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM playlist_entries e
 JOIN grants g ON g.collection_id = e.collection_id AND g.recipient_id = ?
 JOIN device_sessions d ON d.recipient_id = g.recipient_id AND d.id = ? AND d.revoked_at IS NULL
 WHERE e.collection_id = ? AND e.track_id = ?`, session.RecipientID, session.ID, cid, listen.TrackID).Scan(&allowed)
	if err != nil {
		return err
	}
	if allowed != 1 {
		return ErrNotFound
	}
	var oldCID, oldTID, oldRecipient string
	err = tx.QueryRowContext(ctx, `SELECT collection_id, track_id, recipient_id FROM track_listens WHERE id = ?`, listen.ID).Scan(&oldCID, &oldTID, &oldRecipient)
	if err == nil {
		if oldCID != cid || oldTID != listen.TrackID || oldRecipient != session.RecipientID {
			return ErrListenInput
		}
		return tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO track_listens VALUES(?, ?, ?, ?, ?, 'iphone', ?)`, listen.ID, cid, listen.TrackID, session.RecipientID, listen.ListenedMS, nowUnix())
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (a *API) recordListen(w http.ResponseWriter, r *http.Request) {
	var listen Listen
	if err := decodeJSON(r, &listen); err != nil {
		writeError(w, 400, err.Error())
		return
	}
	err := a.store.RecordListen(r.Context(), sessionFromContext(r.Context()), r.PathValue("id"), listen)
	switch {
	case errors.Is(err, ErrListenInput):
		writeError(w, 400, "listens require an iPhone client, a unique ID, and more than 30000 milliseconds of playback")
	case errors.Is(err, ErrNotFound):
		writeError(w, 404, "playlist track not found")
	case err != nil:
		a.internalError(w, r, err)
	default:
		writeJSON(w, http.StatusOK, map[string]bool{"recorded": true})
	}
}
