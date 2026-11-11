package museek

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"os"
	"path/filepath"
	"strings"

	gom "github.com/hajimehoshi/go-mp3"
)

const maxSongBytes = 128 << 20

var ErrUpload = errors.New("upload valid MP3 files, each at most 128 MB")

type pendingSong struct{ path, name, hash string }

// Stage and validate the entire selection before publishing any library records.
func (s *Store) UploadSongs(ctx context.Context, files []*multipart.FileHeader, cid string) (err error) {
	if len(files) == 0 || len(files) > 50 {
		return ErrUpload
	}
	dir := filepath.Join(s.dataDir, "uploads")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	var staged []pendingSong
	defer func() {
		for _, song := range staged {
			os.Remove(song.path)
		}
	}()
	for _, header := range files {
		if !strings.EqualFold(filepath.Ext(header.Filename), ".mp3") || header.Size > maxSongBytes || header.Size == 0 {
			return ErrUpload
		}
		source, err := header.Open()
		if err != nil {
			return err
		}
		tmp, err := os.CreateTemp(dir, ".upload-*")
		if err != nil {
			source.Close()
			return err
		}
		staged = append(staged, pendingSong{path: tmp.Name(), name: filepath.Base(header.Filename)})
		hash := sha256.New()
		_, copyErr := io.Copy(io.MultiWriter(tmp, hash), io.LimitReader(source, maxSongBytes+1))
		source.Close()
		closeErr := tmp.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		check, err := os.Open(tmp.Name())
		if err != nil {
			return err
		}
		decoder, decodeErr := gom.NewDecoder(check)
		valid := decodeErr == nil && decoder.SampleRate() > 0 && decoder.Length() > 0
		check.Close()
		if !valid {
			return ErrUpload
		}
		staged[len(staged)-1].hash = hex.EncodeToString(hash.Sum(nil))
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if cid != "" {
		if err := playlistExists(ctx, tx, cid); err != nil {
			return err
		}
	}
	const libraryID = "uploaded-library"
	_, err = tx.ExecContext(ctx, `INSERT OR IGNORE INTO collections(id,relative_path,name,seen_at,scanned_at,kind) VALUES(?, '@uploads', 'Library uploads', 0, 0, 2)`, libraryID)
	if err != nil {
		return err
	}
	var published []string
	committed := false
	defer func() {
		if !committed {
			for _, path := range published {
				os.Remove(path)
			}
		}
	}()
	for _, song := range staged {
		id := stableID("upload", song.hash)
		var exists int
		if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM tracks WHERE id = ?", id).Scan(&exists); err != nil {
			return err
		}
		if exists == 0 {
			rel := "uploads/" + id + ".mp3"
			path := filepath.Join(s.dataDir, filepath.FromSlash(rel))
			if err := os.Rename(song.path, path); err != nil {
				return err
			}
			published = append(published, path)
			track, err := inspectTrack(path, rel, libraryID)
			if err != nil {
				return err
			}
			fallback := strings.TrimSuffix(song.name, filepath.Ext(song.name))
			if track.Title == id {
				track.Title = fallback
			}
			// Artwork IDs must use the persistent library track ID.
			if track.Artwork != nil {
				art := newArtwork("track-art", id, libraryID, track.Artwork.Data, track.Artwork.ContentType)
				if err := (&Scanner{store: s}).storeArtwork(ctx, tx, art); err != nil {
					return err
				}
				track.ArtworkID = art.ID
			}
			_, err = tx.ExecContext(ctx, `INSERT INTO tracks(id,collection_id,relative_path,file_size,file_mtime_ns,title,artist,album,disc_number,track_number,duration_ms,artwork_id,seen_at,storage) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,'data')`, id, libraryID, rel, track.FileSize, track.MTimeNS, track.Title, track.Artist, track.Album, track.DiscNumber, track.TrackNumber, track.DurationMS, track.ArtworkID)
			if err != nil {
				return fmt.Errorf("index upload: %w", err)
			}
		}
		if cid != "" {
			if err := addPlaylistTrack(ctx, tx, cid, id); err != nil {
				return err
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	committed = true
	return nil
}
