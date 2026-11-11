package museek

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"unicode/utf8"
)

// Existing collection and track IDs stay stable for paired phones and downloads.
// A song now has independent membership, order, and notes in each playlist.
func (s *Store) migratePlaylists(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var version int
	if err := tx.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	if version >= 1 {
		return tx.Commit()
	}
	_, err = tx.ExecContext(ctx, `
ALTER TABLE collections ADD COLUMN kind INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tracks ADD COLUMN storage TEXT NOT NULL DEFAULT 'music';
CREATE TABLE playlist_entries (
 collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
 track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
 position INTEGER NOT NULL,
 PRIMARY KEY(collection_id, track_id)
);
CREATE INDEX playlist_entries_track_idx ON playlist_entries(track_id);
INSERT INTO playlist_entries SELECT collection_id, id,
 ROW_NUMBER() OVER (PARTITION BY collection_id ORDER BY disc_number, track_number, relative_path COLLATE NOCASE) - 1 FROM tracks;
ALTER TABLE track_notes RENAME TO legacy_track_notes;
CREATE TABLE track_notes (
 collection_id TEXT NOT NULL,
 track_id TEXT NOT NULL,
 body TEXT NOT NULL CHECK(length(trim(body)) > 0 AND length(body) <= 10000),
 PRIMARY KEY(collection_id, track_id),
 FOREIGN KEY(collection_id, track_id) REFERENCES playlist_entries(collection_id, track_id) ON DELETE CASCADE
);
INSERT INTO track_notes SELECT * FROM legacy_track_notes;
DROP TABLE legacy_track_notes;
PRAGMA user_version = 1;
`)
	if err != nil {
		return err
	}
	return tx.Commit()
}

var ErrPlaylistInput = errors.New("invalid playlist request")

func (s *Store) CreatePlaylist(ctx context.Context, name, recipientID string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || utf8.RuneCountInString(name) > 200 {
		return "", ErrPlaylistInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM recipients WHERE id = ?", recipientID).Scan(&exists); err != nil {
		return "", err
	}
	if exists != 1 {
		return "", ErrPlaylistInput
	}
	id := randomID()
	_, err = tx.ExecContext(ctx, `INSERT INTO collections(id, relative_path, name, seen_at, scanned_at, kind) VALUES(?, ?, ?, 0, ?, 1)`, id, "@playlist/"+id, name, nowUnix()*1000000000)
	if err != nil {
		return "", err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO grants VALUES(?, ?, ?)`, recipientID, id, nowUnix()); err != nil {
		return "", err
	}
	return id, tx.Commit()
}

func playlistExists(ctx context.Context, tx *sql.Tx, id string) error {
	var n int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM collections WHERE id = ? AND kind <> 2", id).Scan(&n); err != nil {
		return err
	}
	if n != 1 {
		return ErrNotFound
	}
	return nil
}

func addPlaylistTrack(ctx context.Context, tx *sql.Tx, cid, tid string) error {
	if err := playlistExists(ctx, tx, cid); err != nil {
		return err
	}
	var exists int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM tracks WHERE id = ?", tid).Scan(&exists); err != nil {
		return err
	}
	if exists != 1 {
		return ErrNotFound
	}
	_, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO playlist_entries(collection_id,track_id,position) VALUES(?, ?, (SELECT COALESCE(MAX(position),-1)+1 FROM playlist_entries WHERE collection_id = ?))`, cid, tid, cid)
	return err
}

func (s *Store) AddPlaylistTracks(ctx context.Context, cid string, ids []string) error {
	if len(ids) == 0 {
		return ErrPlaylistInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, id := range ids {
		if err := addPlaylistTrack(ctx, tx, cid, id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) RemovePlaylistTrack(ctx context.Context, cid, tid string) error {
	result, err := s.db.ExecContext(ctx, "DELETE FROM playlist_entries WHERE collection_id = ? AND track_id = ?", cid, tid)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// Relative moves read the current order inside the transaction, so concurrent
// edits never resurrect a removed song or overwrite another browser's notes.
func (s *Store) MovePlaylistTrack(ctx context.Context, cid, tid, direction string) error {
	if direction != "up" && direction != "down" {
		return ErrPlaylistInput
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, "SELECT track_id FROM playlist_entries WHERE collection_id = ? ORDER BY position, track_id", cid)
	if err != nil {
		return err
	}
	var ids []string
	index := -1
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		if id == tid {
			index = len(ids)
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	if index < 0 {
		return ErrNotFound
	}
	other := index - 1
	if direction == "down" {
		other = index + 1
	}
	if other >= 0 && other < len(ids) {
		ids[index], ids[other] = ids[other], ids[index]
	}
	for i, id := range ids {
		if _, err := tx.ExecContext(ctx, "UPDATE playlist_entries SET position = ? WHERE collection_id = ? AND track_id = ?", i, cid, id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) libraryTracks(ctx context.Context, query string) ([]Track, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id,title,artist,album,duration_ms FROM tracks
WHERE instr(lower(title || ' ' || artist || ' ' || album), lower(?)) > 0 ORDER BY title COLLATE NOCASE, id`, strings.TrimSpace(query))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Track{}
	for rows.Next() {
		var t Track
		if err := rows.Scan(&t.ID, &t.Title, &t.Artist, &t.Album, &t.DurationMS); err != nil {
			return nil, err
		}
		result = append(result, t)
	}
	return result, rows.Err()
}
