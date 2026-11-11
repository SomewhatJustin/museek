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
	if err = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM tracks WHERE collection_id = ? AND id = ?", collectionID, trackID).Scan(&exists); err != nil {
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
	rows, err := s.db.QueryContext(ctx, "SELECT id, name FROM collections ORDER BY name COLLATE NOCASE")
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
	rows, err := s.db.QueryContext(ctx, `SELECT t.id, t.title, t.artist, COALESCE(n.body, '')
FROM tracks t LEFT JOIN track_notes n ON n.collection_id = t.collection_id AND n.track_id = t.id
WHERE t.collection_id = ? ORDER BY t.disc_number, t.track_number, t.relative_path COLLATE NOCASE`, collectionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []Track
	for rows.Next() {
		t := Track{CollectionID: collectionID}
		if err := rows.Scan(&t.ID, &t.Title, &t.Artist, &t.Note); err != nil {
			return nil, err
		}
		result = append(result, t)
	}
	return result, rows.Err()
}
