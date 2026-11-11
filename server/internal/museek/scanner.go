package museek

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dhowden/tag"
	gom "github.com/hajimehoshi/go-mp3"
)

type Scanner struct {
	store     *Store
	musicRoot string
}

type scannedArtwork struct {
	ID           string
	CollectionID string
	Data         []byte
	ContentType  string
	SourceHash   string
}

type scannedTrack struct {
	ID           string
	CollectionID string
	RelativePath string
	FileSize     int64
	MTimeNS      int64
	Title        string
	Artist       string
	Album        string
	DiscNumber   int
	TrackNumber  int
	DurationMS   int64
	ArtworkID    string
	Artwork      *scannedArtwork
}

type scannedCollection struct {
	ID           string
	RelativePath string
	Name         string
	ArtworkID    string
	Artwork      *scannedArtwork
	Tracks       []scannedTrack
}

type ScanResult struct {
	Collections int `json:"collections"`
	Tracks      int `json:"tracks"`
}

func NewScanner(store *Store, musicRoot string) (*Scanner, error) {
	if strings.TrimSpace(musicRoot) == "" {
		return nil, errors.New("music directory is required")
	}
	abs, err := filepath.Abs(musicRoot)
	if err != nil {
		return nil, fmt.Errorf("resolve music directory: %w", err)
	}
	info, err := os.Stat(abs)
	if err != nil {
		return nil, fmt.Errorf("open music directory: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("music path is not a directory: %s", abs)
	}
	return &Scanner{store: store, musicRoot: abs}, nil
}

func (s *Scanner) Scan(ctx context.Context) (ScanResult, error) {
	collections, err := s.readFilesystem(ctx)
	if err != nil {
		return ScanResult{}, err
	}
	seen := time.Now().UTC().UnixNano()
	tx, err := s.store.db.BeginTx(ctx, nil)
	if err != nil {
		return ScanResult{}, fmt.Errorf("begin scan: %w", err)
	}
	defer tx.Rollback()

	trackCount := 0
	for _, collection := range collections {
		_, err = tx.ExecContext(ctx, `
INSERT INTO collections (id, relative_path, name, artwork_id, seen_at, scanned_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  relative_path=excluded.relative_path,
  name=excluded.name,
  artwork_id=excluded.artwork_id,
  seen_at=excluded.seen_at,
  scanned_at=excluded.scanned_at`,
			collection.ID, collection.RelativePath, collection.Name, collection.ArtworkID, seen, seen)
		if err != nil {
			return ScanResult{}, fmt.Errorf("index collection %q: %w", collection.Name, err)
		}
		if collection.Artwork != nil {
			if err := s.storeArtwork(ctx, tx, *collection.Artwork); err != nil {
				return ScanResult{}, err
			}
		}

		for _, track := range collection.Tracks {
			trackCount++
			if track.Artwork != nil {
				if err := s.storeArtwork(ctx, tx, *track.Artwork); err != nil {
					return ScanResult{}, err
				}
			}
			var existing int
			if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM tracks WHERE id = ?", track.ID).Scan(&existing); err != nil {
				return ScanResult{}, err
			}
			_, err = tx.ExecContext(ctx, `
INSERT INTO tracks (
  id, collection_id, relative_path, file_size, file_mtime_ns, title, artist, album,
  disc_number, track_number, duration_ms, artwork_id, seen_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  collection_id=excluded.collection_id,
  relative_path=excluded.relative_path,
  file_size=excluded.file_size,
  file_mtime_ns=excluded.file_mtime_ns,
  title=excluded.title,
  artist=excluded.artist,
  album=excluded.album,
  disc_number=excluded.disc_number,
  track_number=excluded.track_number,
  duration_ms=excluded.duration_ms,
  artwork_id=excluded.artwork_id,
  seen_at=excluded.seen_at`,
				track.ID, track.CollectionID, track.RelativePath, track.FileSize, track.MTimeNS,
				track.Title, track.Artist, track.Album, track.DiscNumber, track.TrackNumber,
				track.DurationMS, track.ArtworkID, seen)
			if err != nil {
				return ScanResult{}, fmt.Errorf("index track %q: %w", track.RelativePath, err)
			}
			if existing == 0 {
				if _, err := tx.ExecContext(ctx, `INSERT INTO playlist_entries(collection_id, track_id, position) VALUES(?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_entries WHERE collection_id = ?))`, collection.ID, track.ID, collection.ID); err != nil {
					return ScanResult{}, err
				}
			}
		}
	}

	if _, err := tx.ExecContext(ctx, `DELETE FROM tracks WHERE storage = 'music' AND seen_at <> ?`, seen); err != nil {
		return ScanResult{}, fmt.Errorf("remove missing tracks: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM collections WHERE kind = 0 AND seen_at <> ?`, seen); err != nil {
		return ScanResult{}, fmt.Errorf("remove missing collections: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
DELETE FROM artworks
WHERE id NOT IN (SELECT artwork_id FROM collections WHERE artwork_id <> '')
  AND id NOT IN (SELECT artwork_id FROM tracks WHERE artwork_id <> '')`); err != nil {
		return ScanResult{}, fmt.Errorf("remove stale artwork records: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return ScanResult{}, fmt.Errorf("commit scan: %w", err)
	}
	return ScanResult{Collections: len(collections), Tracks: trackCount}, nil
}

func (s *Scanner) readFilesystem(ctx context.Context) ([]scannedCollection, error) {
	entries, err := os.ReadDir(s.musicRoot)
	if err != nil {
		return nil, fmt.Errorf("read music directory: %w", err)
	}
	collections := make([]scannedCollection, 0, len(entries))
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		rel := filepath.ToSlash(entry.Name())
		collection := scannedCollection{
			ID:           stableID("collection", rel),
			RelativePath: rel,
			Name:         entry.Name(),
		}
		folder := filepath.Join(s.musicRoot, entry.Name())
		if art, ok, err := readCoverArtwork(folder, collection.ID); err != nil {
			return nil, err
		} else if ok {
			collection.Artwork = &art
			collection.ArtworkID = art.ID
		}

		err := filepath.WalkDir(folder, func(path string, d fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			if d.Type()&os.ModeSymlink != 0 {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if d.IsDir() || !strings.EqualFold(filepath.Ext(d.Name()), ".mp3") {
				return nil
			}
			relPath, err := filepath.Rel(s.musicRoot, path)
			if err != nil {
				return err
			}
			track, err := inspectTrack(path, filepath.ToSlash(relPath), collection.ID)
			if err != nil {
				return err
			}
			collection.Tracks = append(collection.Tracks, track)
			if collection.ArtworkID == "" && track.Artwork != nil {
				collection.ArtworkID = track.Artwork.ID
			}
			return nil
		})
		if err != nil {
			return nil, fmt.Errorf("scan collection %q: %w", collection.Name, err)
		}
		sort.Slice(collection.Tracks, func(i, j int) bool {
			a, b := collection.Tracks[i], collection.Tracks[j]
			if a.DiscNumber != b.DiscNumber {
				return a.DiscNumber < b.DiscNumber
			}
			if a.TrackNumber != b.TrackNumber {
				return a.TrackNumber < b.TrackNumber
			}
			return strings.ToLower(a.RelativePath) < strings.ToLower(b.RelativePath)
		})
		collections = append(collections, collection)
	}
	return collections, nil
}

func inspectTrack(path, relativePath, collectionID string) (scannedTrack, error) {
	info, err := os.Stat(path)
	if err != nil {
		return scannedTrack{}, err
	}
	trackID := stableID("track", relativePath)
	result := scannedTrack{
		ID:           trackID,
		CollectionID: collectionID,
		RelativePath: relativePath,
		FileSize:     info.Size(),
		MTimeNS:      info.ModTime().UnixNano(),
		Title:        strings.TrimSuffix(filepath.Base(path), filepath.Ext(path)),
	}

	file, err := os.Open(path)
	if err != nil {
		return scannedTrack{}, err
	}
	metadata, tagErr := tag.ReadFrom(file)
	file.Close()
	if tagErr == nil {
		if title := strings.TrimSpace(metadata.Title()); title != "" {
			result.Title = title
		}
		result.Artist = strings.TrimSpace(metadata.Artist())
		result.Album = strings.TrimSpace(metadata.Album())
		result.TrackNumber, _ = metadata.Track()
		result.DiscNumber, _ = metadata.Disc()
		if picture := metadata.Picture(); picture != nil && len(picture.Data) > 0 {
			contentType := picture.MIMEType
			if contentType == "" {
				contentType = http.DetectContentType(picture.Data)
			}
			art := newArtwork("track-art", trackID, collectionID, picture.Data, contentType)
			result.ArtworkID = art.ID
			result.Artwork = &art
		}
	}

	durationFile, err := os.Open(path)
	if err == nil {
		if decoder, decodeErr := gom.NewDecoder(durationFile); decodeErr == nil && decoder.SampleRate() > 0 && decoder.Length() > 0 {
			result.DurationMS = decoder.Length() * 1000 / int64(decoder.SampleRate()*4)
		}
		durationFile.Close()
	}
	return result, nil
}

func readCoverArtwork(folder, collectionID string) (scannedArtwork, bool, error) {
	for _, name := range []string{"cover.jpg", "cover.jpeg", "cover.png"} {
		path := filepath.Join(folder, name)
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return scannedArtwork{}, false, fmt.Errorf("read artwork %q: %w", path, err)
		}
		return newArtwork("collection-art", collectionID, collectionID, data, http.DetectContentType(data)), true, nil
	}
	return scannedArtwork{}, false, nil
}

func newArtwork(kind, ownerID, collectionID string, data []byte, contentType string) scannedArtwork {
	hash := sha256.Sum256(data)
	return scannedArtwork{
		ID:           stableID(kind, ownerID),
		CollectionID: collectionID,
		Data:         data,
		ContentType:  contentType,
		SourceHash:   hex.EncodeToString(hash[:]),
	}
}

func (s *Scanner) storeArtwork(ctx context.Context, tx *sql.Tx, art scannedArtwork) error {
	dir := filepath.Join(s.store.dataDir, "artwork")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create artwork cache: %w", err)
	}
	rel := filepath.ToSlash(filepath.Join("artwork", art.ID+".bin"))
	abs := filepath.Join(s.store.dataDir, filepath.FromSlash(rel))
	if existing, err := os.ReadFile(abs); err != nil || sha256Hex(existing) != art.SourceHash {
		tmp, err := os.CreateTemp(dir, ".artwork-*")
		if err != nil {
			return fmt.Errorf("create artwork cache file: %w", err)
		}
		tmpName := tmp.Name()
		defer os.Remove(tmpName)
		if err := tmp.Chmod(0o600); err != nil {
			tmp.Close()
			return err
		}
		if _, err := tmp.Write(art.Data); err != nil {
			tmp.Close()
			return fmt.Errorf("write artwork cache: %w", err)
		}
		if err := tmp.Close(); err != nil {
			return err
		}
		if err := os.Rename(tmpName, abs); err != nil {
			return fmt.Errorf("publish artwork cache: %w", err)
		}
	}
	_, err := tx.ExecContext(ctx, `
INSERT INTO artworks (id, collection_id, relative_cache_path, content_type, source_hash)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  collection_id=excluded.collection_id,
  relative_cache_path=excluded.relative_cache_path,
  content_type=excluded.content_type,
  source_hash=excluded.source_hash`,
		art.ID, art.CollectionID, rel, art.ContentType, art.SourceHash)
	if err != nil {
		return fmt.Errorf("index artwork: %w", err)
	}
	return nil
}

func stableID(kind, value string) string {
	hash := sha256.Sum256([]byte(kind + "\x00" + value))
	return hex.EncodeToString(hash[:16])
}

func sha256Hex(data []byte) string {
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}
