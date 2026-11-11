package museek

import (
	"context"
	"errors"
	"strings"
	"unicode/utf8"
)

const MaxNoteLength = 10000

var ErrNoteTooLong = errors.New("notes must be at most 10000 characters")

// SetTrackNote writes only an existing playlist entry; blank text removes its note.
func (s *Store) SetTrackNote(ctx context.Context, collectionID, trackID, body string) error {
	body = strings.TrimSpace(body)
	if utf8.RuneCountInString(body) > MaxNoteLength {
		return ErrNoteTooLong
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exists int
	if err = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM playlist_entries WHERE collection_id = ? AND track_id = ?", collectionID, trackID).Scan(&exists); err != nil {
		return err
	}
	if exists == 0 {
		return ErrNotFound
	}
	if body == "" {
		_, err = tx.ExecContext(ctx, "DELETE FROM track_notes WHERE collection_id = ? AND track_id = ?", collectionID, trackID)
	} else {
		_, err = tx.ExecContext(ctx, `INSERT INTO track_notes (collection_id, track_id, body) VALUES (?, ?, ?)
ON CONFLICT(collection_id, track_id) DO UPDATE SET body = excluded.body`, collectionID, trackID, body)
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) noteCollections(ctx context.Context) ([]Collection, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id, name FROM collections WHERE kind <> 2 ORDER BY name COLLATE NOCASE")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []Collection
	for rows.Next() {
		var c Collection
		if err := rows.Scan(&c.ID, &c.Name); err != nil {
			return nil, err
		}
		result = append(result, c)
	}
	return result, rows.Err()
}

func (s *Store) noteTracks(ctx context.Context, collectionID string) ([]Track, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT t.id, t.title, t.artist, COALESCE(n.body, ''),
(SELECT COUNT(*) FROM track_listens l WHERE l.collection_id = e.collection_id AND l.track_id = e.track_id)
FROM playlist_entries e JOIN tracks t ON t.id = e.track_id LEFT JOIN track_notes n ON n.collection_id = e.collection_id AND n.track_id = t.id
WHERE e.collection_id = ? ORDER BY e.position, e.track_id`, collectionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []Track
	for rows.Next() {
		t := Track{CollectionID: collectionID}
		if err := rows.Scan(&t.ID, &t.Title, &t.Artist, &t.Note, &t.PlayCount); err != nil {
			return nil, err
		}
		result = append(result, t)
	}
	return result, rows.Err()
}
