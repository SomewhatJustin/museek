package museek

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestNotesBelongToExistingPlaylistEntries(t *testing.T) {
	sys := newTestSystem(t)
	token, collectionID, trackID, _ := sys.inviteAndPair(t)
	ctx := context.Background()
	otherID, err := sys.store.collectionIDByName(ctx, "Private Collection")
	if err != nil {
		t.Fatal(err)
	}
	// Identical audio in another folder is another playlist entry.
	if err := os.WriteFile(filepath.Join(sys.musicDir, "Private Collection", "Copy.mp3"), sys.trackBytes, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := sys.scanner.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	if err := sys.store.SetTrackNote(ctx, collectionID, trackID, "  A personal note <script>alert(1)</script>  "); err != nil {
		t.Fatal(err)
	}
	if err := sys.store.SetTrackNote(ctx, otherID, trackID, "Wrong playlist"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("mismatched entry: %v", err)
	}
	if err := sys.store.SetTrackNote(ctx, collectionID, "missing", "Orphan"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing entry: %v", err)
	}
	if _, err := sys.store.db.ExecContext(ctx, "INSERT INTO track_notes VALUES (?, ?, ?)", otherID, trackID, "Invalid"); err == nil {
		t.Fatal("database accepted mismatched playlist/track")
	}
	if _, err := sys.scanner.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("GET", sys.server.URL+"/v1/collections/"+collectionID, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var detail CollectionDetail
	if err := json.NewDecoder(response.Body).Decode(&detail); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 || len(detail.Tracks) != 1 || detail.Tracks[0].Note != "A personal note <script>alert(1)</script>" {
		t.Fatalf("note did not survive scan/API: %+v", detail)
	}
	other, err := sys.store.noteTracks(ctx, otherID)
	if err != nil {
		t.Fatal(err)
	}
	for _, track := range other {
		if track.Note != "" {
			t.Fatal("note leaked to another playlist")
		}
	}
	if err := sys.store.SetTrackNote(ctx, collectionID, trackID, "Replacement"); err != nil {
		t.Fatal(err)
	}
	var count int
	sys.store.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM track_notes").Scan(&count)
	if count != 1 {
		t.Fatalf("expected one note, got %d", count)
	}
	if err := sys.store.SetTrackNote(ctx, collectionID, trackID, strings.Repeat("x", MaxNoteLength+1)); !errors.Is(err, ErrNoteTooLong) {
		t.Fatalf("length: %v", err)
	}
	if err := sys.store.SetTrackNote(ctx, collectionID, trackID, " \n "); err != nil {
		t.Fatal(err)
	}
	tracks, err := sys.store.noteTracks(ctx, collectionID)
	if err != nil {
		t.Fatal(err)
	}
	if tracks[0].Note != "" {
		t.Fatal("blank note not removed")
	}
	if err := sys.store.SetTrackNote(ctx, collectionID, trackID, "Delete with song"); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(sys.musicDir, "Bedtime Favorites", "01 Lullaby.mp3")); err != nil {
		t.Fatal(err)
	}
	if _, err := sys.scanner.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	sys.store.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM track_notes").Scan(&count)
	if count != 0 {
		t.Fatal("orphan note survived removal")
	}
}

func TestNoteEditorFormAndLocalBoundary(t *testing.T) {
	sys := newTestSystem(t)
	_, cid, tid, _ := sys.inviteAndPair(t)
	handler, err := sys.store.NoteEditorHandler()
	if err != nil {
		t.Fatal(err)
	}
	get := httptest.NewRequest("GET", "http://127.0.0.1:8081/?collection="+cid, nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, get)
	if w.Code != 200 {
		t.Fatalf("editor status %d: %s", w.Code, w.Body.String())
	}
	token := regexp.MustCompile(`name="csrf" value="([^"]+)"`).FindStringSubmatch(w.Body.String())
	if len(token) != 2 {
		t.Fatal("missing CSRF token")
	}
	post := func(host, csrf, note string) *httptest.ResponseRecorder {
		values := url.Values{"csrf": {csrf}, "collection": {cid}, "track": {tid}, "note": {note}}
		req := httptest.NewRequest("POST", "http://"+host+"/", strings.NewReader(values.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		result := httptest.NewRecorder()
		handler.ServeHTTP(result, req)
		return result
	}
	if r := post("127.0.0.1:8081", "bad", "bad"); r.Code != 403 {
		t.Fatalf("csrf status %d", r.Code)
	}
	if r := post("attacker.example:8081", token[1], "bad"); r.Code != 403 {
		t.Fatalf("host status %d", r.Code)
	}
	if r := post("127.0.0.1:8081", token[1], "</textarea><script>alert(1)</script>"); r.Code != 303 {
		t.Fatalf("save status %d: %s", r.Code, r.Body.String())
	}
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, get)
	if strings.Contains(w.Body.String(), "<script>") || !strings.Contains(w.Body.String(), "&lt;script&gt;") {
		t.Fatal("note not HTML escaped")
	}
	// Listener sessions cannot edit notes on the public server.
	req, _ := http.NewRequest("POST", sys.server.URL+"/", strings.NewReader(""))
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if response.StatusCode != 404 {
		t.Fatalf("owner editor exposed publicly: %d", response.StatusCode)
	}
}
