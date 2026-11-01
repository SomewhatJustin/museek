package museek

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

var (
	ErrNotFound     = errors.New("not found")
	ErrUnauthorized = errors.New("unauthorized")
	ErrCodeInvalid  = errors.New("pairing code is invalid or expired")
)

type Store struct {
	db      *sql.DB
	dataDir string
}

func OpenStore(dataDir string) (*Store, error) {
	if strings.TrimSpace(dataDir) == "" {
		return nil, errors.New("data directory is required")
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create data directory: %w", err)
	}
	dbPath := filepath.Join(dataDir, "museek.db")
	dsn := "file:" + dbPath + "?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	db.SetMaxOpenConns(1)
	store := &Store{db: db, dataDir: dataDir}
	if err := store.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return store, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate(ctx context.Context) error {
	const schema = `
CREATE TABLE IF NOT EXISTS collections (
  id TEXT PRIMARY KEY,
  relative_path TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  artwork_id TEXT NOT NULL DEFAULT '',
  seen_at INTEGER NOT NULL,
  scanned_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tracks (
  id TEXT PRIMARY KEY,
  collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL UNIQUE,
  file_size INTEGER NOT NULL,
  file_mtime_ns INTEGER NOT NULL,
  title TEXT NOT NULL,
  artist TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '',
  disc_number INTEGER NOT NULL DEFAULT 0,
  track_number INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  artwork_id TEXT NOT NULL DEFAULT '',
  seen_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS tracks_collection_idx ON tracks(collection_id);
CREATE TABLE IF NOT EXISTS artworks (
  id TEXT PRIMARY KEY,
  collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  relative_cache_path TEXT NOT NULL,
  content_type TEXT NOT NULL,
  source_hash TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS recipients (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL COLLATE NOCASE UNIQUE,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS grants (
  recipient_id TEXT NOT NULL REFERENCES recipients(id) ON DELETE CASCADE,
  collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (recipient_id, collection_id)
);
CREATE TABLE IF NOT EXISTS pairing_codes (
  id TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL UNIQUE,
  recipient_id TEXT NOT NULL REFERENCES recipients(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL,
  used_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS device_sessions (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  recipient_id TEXT NOT NULL REFERENCES recipients(id) ON DELETE CASCADE,
  device_name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX IF NOT EXISTS sessions_token_idx ON device_sessions(token_hash);
`
	if _, err := s.db.ExecContext(ctx, schema); err != nil {
		return fmt.Errorf("migrate database: %w", err)
	}
	return nil
}

func nowUnix() int64 { return time.Now().UTC().Unix() }
