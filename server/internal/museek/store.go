package museek

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

func (s *Store) EnsureRecipient(ctx context.Context, name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", errors.New("recipient name is required")
	}
	var id string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM recipients WHERE name = ? COLLATE NOCASE`, name).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	id = randomID()
	_, err = s.db.ExecContext(ctx, `INSERT INTO recipients (id, name, created_at) VALUES (?, ?, ?)`, id, name, nowUnix())
	if err != nil {
		return "", fmt.Errorf("create recipient: %w", err)
	}
	return id, nil
}

func (s *Store) collectionIDByName(ctx context.Context, name string) (string, error) {
	var id string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM collections WHERE name = ? COLLATE NOCASE`, strings.TrimSpace(name)).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", fmt.Errorf("collection %q: %w", name, ErrNotFound)
	}
	return id, err
}

func (s *Store) SetGrant(ctx context.Context, recipientName, collectionName string, granted bool) error {
	var recipientID string
	err := s.db.QueryRowContext(ctx, `SELECT id FROM recipients WHERE name = ? COLLATE NOCASE`, strings.TrimSpace(recipientName)).Scan(&recipientID)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("recipient %q: %w", recipientName, ErrNotFound)
	}
	if err != nil {
		return err
	}
	collectionID, err := s.collectionIDByName(ctx, collectionName)
	if err != nil {
		return err
	}
	if granted {
		_, err = s.db.ExecContext(ctx, `INSERT OR IGNORE INTO grants (recipient_id, collection_id, created_at) VALUES (?, ?, ?)`, recipientID, collectionID, nowUnix())
	} else {
		_, err = s.db.ExecContext(ctx, `DELETE FROM grants WHERE recipient_id = ? AND collection_id = ?`, recipientID, collectionID)
	}
	return err
}

func (s *Store) CreateInvite(ctx context.Context, recipientName, collectionName string, validFor time.Duration) (string, error) {
	if validFor <= 0 {
		validFor = 24 * time.Hour
	}
	recipientID, err := s.EnsureRecipient(ctx, recipientName)
	if err != nil {
		return "", err
	}
	collectionID, err := s.collectionIDByName(ctx, collectionName)
	if err != nil {
		return "", err
	}
	if _, err := s.db.ExecContext(ctx, `INSERT OR IGNORE INTO grants (recipient_id, collection_id, created_at) VALUES (?, ?, ?)`, recipientID, collectionID, nowUnix()); err != nil {
		return "", fmt.Errorf("grant collection: %w", err)
	}
	code, err := randomPairCode()
	if err != nil {
		return "", err
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO pairing_codes (id, code_hash, recipient_id, expires_at, created_at)
VALUES (?, ?, ?, ?, ?)`, randomID(), hashSecret(normalizeCode(code)), recipientID, time.Now().UTC().Add(validFor).Unix(), nowUnix())
	if err != nil {
		return "", fmt.Errorf("create pairing code: %w", err)
	}
	return code, nil
}

func (s *Store) Pair(ctx context.Context, code, deviceName string) (PairResult, error) {
	deviceName = strings.TrimSpace(deviceName)
	if deviceName == "" {
		deviceName = "iPhone"
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PairResult{}, err
	}
	defer tx.Rollback()
	var recipientID string
	err = tx.QueryRowContext(ctx, `
UPDATE pairing_codes SET used_at = ?
WHERE code_hash = ? AND expires_at > ?
RETURNING recipient_id`, nowUnix(), hashSecret(normalizeCode(code)), nowUnix()).Scan(&recipientID)
	if errors.Is(err, sql.ErrNoRows) {
		return PairResult{}, ErrCodeInvalid
	}
	if err != nil {
		return PairResult{}, fmt.Errorf("consume pairing code: %w", err)
	}
	token, err := randomToken(32)
	if err != nil {
		return PairResult{}, err
	}
	sessionID := randomID()
	_, err = tx.ExecContext(ctx, `
INSERT INTO device_sessions (id, token_hash, recipient_id, device_name, created_at, last_used_at)
VALUES (?, ?, ?, ?, ?, ?)`, sessionID, hashSecret(token), recipientID, deviceName, nowUnix(), nowUnix())
	if err != nil {
		return PairResult{}, fmt.Errorf("create device session: %w", err)
	}
	var result PairResult
	result.Token = token
	result.Recipient.ID = recipientID
	if err := tx.QueryRowContext(ctx, `SELECT name FROM recipients WHERE id = ?`, recipientID).Scan(&result.Recipient.Name); err != nil {
		return PairResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return PairResult{}, err
	}
	return result, nil
}

func (s *Store) Authenticate(ctx context.Context, token string) (Session, error) {
	if token == "" {
		return Session{}, ErrUnauthorized
	}
	var session Session
	err := s.db.QueryRowContext(ctx, `
SELECT id, recipient_id, device_name
FROM device_sessions
WHERE token_hash = ? AND revoked_at IS NULL`, hashSecret(token)).Scan(&session.ID, &session.RecipientID, &session.DeviceName)
	if errors.Is(err, sql.ErrNoRows) {
		return Session{}, ErrUnauthorized
	}
	if err != nil {
		return Session{}, err
	}
	_, _ = s.db.ExecContext(ctx, `UPDATE device_sessions SET last_used_at = ? WHERE id = ?`, nowUnix(), session.ID)
	return session, nil
}

func (s *Store) ActiveSessionByID(ctx context.Context, id string) (Session, error) {
	var session Session
	err := s.db.QueryRowContext(ctx, `
SELECT id, recipient_id, device_name FROM device_sessions WHERE id = ? AND revoked_at IS NULL`, id).
		Scan(&session.ID, &session.RecipientID, &session.DeviceName)
	if errors.Is(err, sql.ErrNoRows) {
		return Session{}, ErrUnauthorized
	}
	return session, err
}

func (s *Store) ListCollections(ctx context.Context, recipientID string) ([]Collection, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT c.id, c.name, c.artwork_id, COUNT(e.track_id), c.scanned_at
FROM collections c
JOIN grants g ON g.collection_id = c.id AND g.recipient_id = ?
LEFT JOIN playlist_entries e ON e.collection_id = c.id
GROUP BY c.id
ORDER BY c.name COLLATE NOCASE`, recipientID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	collections := []Collection{}
	for rows.Next() {
		var item Collection
		var scanned int64
		if err := rows.Scan(&item.ID, &item.Name, &item.ArtworkID, &item.TrackCount, &scanned); err != nil {
			return nil, err
		}
		item.LastScanned = time.Unix(0, scanned).UTC()
		collections = append(collections, item)
	}
	return collections, rows.Err()
}

func (s *Store) CollectionDetail(ctx context.Context, recipientID, collectionID string) (CollectionDetail, error) {
	var result CollectionDetail
	var scanned int64
	err := s.db.QueryRowContext(ctx, `
SELECT c.id, c.name, c.artwork_id, COUNT(e.track_id), c.scanned_at
FROM collections c
JOIN grants g ON g.collection_id = c.id AND g.recipient_id = ?
LEFT JOIN playlist_entries e ON e.collection_id = c.id
WHERE c.id = ?
GROUP BY c.id`, recipientID, collectionID).
		Scan(&result.ID, &result.Name, &result.ArtworkID, &result.TrackCount, &scanned)
	if errors.Is(err, sql.ErrNoRows) {
		return CollectionDetail{}, ErrNotFound
	}
	if err != nil {
		return CollectionDetail{}, err
	}
	result.LastScanned = time.Unix(0, scanned).UTC()
	rows, err := s.db.QueryContext(ctx, `
SELECT t.id, e.collection_id, t.title, t.artist, t.album, t.disc_number, t.track_number, t.duration_ms, t.artwork_id, COALESCE(n.body, '')
FROM playlist_entries e JOIN tracks t ON t.id = e.track_id
LEFT JOIN track_notes n ON n.collection_id = e.collection_id AND n.track_id = e.track_id
WHERE e.collection_id = ?
ORDER BY e.position, e.track_id`, collectionID)
	if err != nil {
		return CollectionDetail{}, err
	}
	defer rows.Close()
	result.Tracks = []Track{}
	for rows.Next() {
		var track Track
		if err := rows.Scan(&track.ID, &track.CollectionID, &track.Title, &track.Artist, &track.Album, &track.DiscNumber, &track.TrackNumber, &track.DurationMS, &track.ArtworkID, &track.Note); err != nil {
			return CollectionDetail{}, err
		}
		result.Tracks = append(result.Tracks, track)
	}
	return result, rows.Err()
}

func (s *Store) TrackForRecipient(ctx context.Context, recipientID, trackID string) (TrackFile, error) {
	var track TrackFile
	var mtimeNS int64
	err := s.db.QueryRowContext(ctx, `
SELECT t.id, e.collection_id, t.title, t.artist, t.album, t.disc_number, t.track_number,
       t.duration_ms, t.artwork_id, t.relative_path, t.file_mtime_ns, t.storage
FROM tracks t
JOIN playlist_entries e ON e.track_id = t.id
JOIN grants g ON g.collection_id = e.collection_id AND g.recipient_id = ?
WHERE t.id = ? LIMIT 1`, recipientID, trackID).
		Scan(&track.ID, &track.CollectionID, &track.Title, &track.Artist, &track.Album, &track.DiscNumber,
			&track.TrackNumber, &track.DurationMS, &track.ArtworkID, &track.RelativePath, &mtimeNS, &track.Storage)
	if errors.Is(err, sql.ErrNoRows) {
		return TrackFile{}, ErrNotFound
	}
	track.ModifiedAt = time.Unix(0, mtimeNS)
	return track, err
}

func (s *Store) ArtworkForRecipient(ctx context.Context, recipientID, artworkID string) (path, contentType string, err error) {
	var rel string
	err = s.db.QueryRowContext(ctx, `
SELECT a.relative_cache_path, a.content_type
FROM artworks a
WHERE a.id = ? AND (EXISTS (SELECT 1 FROM grants g WHERE g.collection_id = a.collection_id AND g.recipient_id = ?)
OR EXISTS (SELECT 1 FROM tracks t JOIN playlist_entries e ON e.track_id = t.id JOIN grants g ON g.collection_id = e.collection_id WHERE t.artwork_id = a.id AND g.recipient_id = ?))`, artworkID, recipientID, recipientID).Scan(&rel, &contentType)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrNotFound
	}
	if err != nil {
		return "", "", err
	}
	path = filepath.Join(s.dataDir, filepath.FromSlash(rel))
	return path, contentType, nil
}

func (s *Store) ListDevices(ctx context.Context, recipientName string) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT d.id, d.device_name, d.created_at, d.last_used_at, d.revoked_at
FROM device_sessions d
JOIN recipients r ON r.id = d.recipient_id
WHERE r.name = ? COLLATE NOCASE
ORDER BY d.created_at DESC`, strings.TrimSpace(recipientName))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := []Device{}
	for rows.Next() {
		var item Device
		var created, used int64
		var revoked sql.NullInt64
		if err := rows.Scan(&item.ID, &item.Name, &created, &used, &revoked); err != nil {
			return nil, err
		}
		item.CreatedAt = time.Unix(created, 0).UTC()
		item.LastUsed = time.Unix(used, 0).UTC()
		if revoked.Valid {
			t := time.Unix(revoked.Int64, 0).UTC()
			item.RevokedAt = &t
		}
		devices = append(devices, item)
	}
	return devices, rows.Err()
}

func (s *Store) RevokeDevice(ctx context.Context, deviceID string) error {
	result, err := s.db.ExecContext(ctx, `UPDATE device_sessions SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, nowUnix(), deviceID)
	if err != nil {
		return err
	}
	count, _ := result.RowsAffected()
	if count == 0 {
		return ErrNotFound
	}
	return nil
}

func randomToken(size int) (string, error) {
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func randomID() string {
	data := make([]byte, 16)
	if _, err := rand.Read(data); err != nil {
		panic(err)
	}
	return hex.EncodeToString(data)
}

func randomPairCode() (string, error) {
	const alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
	data := make([]byte, 8)
	random := make([]byte, 8)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	for i := range data {
		data[i] = alphabet[int(random[i])%len(alphabet)]
	}
	return string(data[:4]) + "-" + string(data[4:]), nil
}

func normalizeCode(code string) string {
	return strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(code), "-", ""))
}

func hashSecret(secret string) string {
	hash := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(hash[:])
}
