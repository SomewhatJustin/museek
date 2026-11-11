package museek

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestPlaylistManagerWorkflowAndPhoneAPI(t *testing.T) {
	sys := newTestSystem(t)
	token, originalID, tid, _ := sys.inviteAndPair(t)
	ctx := context.Background()
	session, err := sys.store.Authenticate(ctx, token)
	if err != nil {
		t.Fatal(err)
	}
	handler, err := sys.store.ManagementHandler(`["owner@example.com"]`)
	if err != nil {
		t.Fatal(err)
	}
	get := func(path string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", path, nil)
		r.Header.Set("Tailscale-User-Login", "owner@example.com")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	w := get("/manage/")
	if w.Header().Get("Referrer-Policy") != "same-origin" {
		t.Fatal("form submissions need a nonopaque same-origin Origin")
	}
	if w.Code != 200 {
		t.Fatalf("manager page: %d %s", w.Code, w.Body.String())
	}
	match := regexp.MustCompile(`name="csrf" value="([^"]+)"`).FindStringSubmatch(w.Body.String())
	if len(match) != 2 {
		t.Fatal("no csrf")
	}
	csrf := match[1]
	post := func(values url.Values) *httptest.ResponseRecorder {
		values.Set("csrf", csrf)
		r := httptest.NewRequest("POST", "/manage/", strings.NewReader(values.Encode()))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Origin", "http://example.com")
		r.Header.Set("Tailscale-User-Login", "owner@example.com")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != 303 {
			t.Fatalf("manager write: %d %s", w.Code, w.Body.String())
		}
		return w
	}
	w = post(url.Values{"action": {"create"}, "name": {"Laptop mix"}, "recipient": {session.RecipientID}})
	location, err := url.Parse(w.Header().Get("Location"))
	if err != nil {
		t.Fatal(err)
	}
	cid := location.Query().Get("collection")
	other, err := sys.store.noteTracks(ctx, stableID("collection", "Private Collection"))
	if err != nil {
		t.Fatal(err)
	}
	otherID := other[0].ID
	post(url.Values{"action": {"add"}, "collection": {cid}, "tracks": {tid, otherID}})
	post(url.Values{"action": {"note"}, "collection": {cid}, "track": {tid}, "note": {"Laptop-only note <script>alert(1)</script>"}})
	post(url.Values{"action": {"up"}, "collection": {cid}, "track": {otherID}})
	if _, err := sys.scanner.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	// Exercise the exact authenticated endpoint used by the existing iPhone app.
	r, _ := http.NewRequest("GET", sys.server.URL+"/v1/collections/"+cid, nil)
	r.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var detail CollectionDetail
	if err := json.NewDecoder(response.Body).Decode(&detail); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 || len(detail.Tracks) != 2 || detail.Tracks[0].ID != otherID || detail.Tracks[1].Note != "Laptop-only note <script>alert(1)</script>" || detail.Tracks[1].CollectionID != cid {
		t.Fatalf("phone detail: %+v", detail)
	}
	original, err := sys.store.CollectionDetail(ctx, session.RecipientID, originalID)
	if err != nil || original.Tracks[0].Note != "" {
		t.Fatalf("note leaked: %+v %v", original, err)
	}
	w = get("/manage/?collection=" + cid)
	if w.Code != 200 || strings.Contains(w.Body.String(), "<script>alert(1)</script>") || !strings.Contains(w.Body.String(), "&lt;script&gt;") {
		t.Fatal("playlist page did not escape notes")
	}
	post(url.Values{"action": {"remove"}, "collection": {cid}, "track": {tid}})
	if _, err := sys.scanner.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	detail, err = sys.store.CollectionDetail(ctx, session.RecipientID, cid)
	if err != nil || len(detail.Tracks) != 1 {
		t.Fatalf("removal lost: %+v %v", detail, err)
	}
	library, err := sys.store.libraryTracks(ctx, "")
	if err != nil || len(library) != 2 {
		t.Fatalf("removal deleted library song: %+v %v", library, err)
	}
	// Removing a scanned song from its original playlist also survives rescans.
	post(url.Values{"action": {"remove"}, "collection": {originalID}, "track": {tid}})
	if _, err := sys.scanner.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	original, err = sys.store.CollectionDetail(ctx, session.RecipientID, originalID)
	if err != nil || len(original.Tracks) != 0 {
		t.Fatalf("scanner resurrected entry: %+v %v", original, err)
	}
	post(url.Values{"action": {"add"}, "collection": {cid}, "tracks": {tid, tid}})
	detail, err = sys.store.CollectionDetail(ctx, session.RecipientID, cid)
	if err != nil || len(detail.Tracks) != 2 || detail.Tracks[1].Note != "" {
		t.Fatalf("re-add: %+v %v", detail, err)
	}
}

func TestManagerAuthorizationAndCSRF(t *testing.T) {
	sys := newTestSystem(t)
	sys.inviteAndPair(t)
	for _, raw := range []string{"", `null`, `[]`, `{}`, `[""]`, `[" owner"]`, `["a,b"]`, `["owner","owner"]`, `["owner"] {}`} {
		if _, err := sys.store.ManagementHandler(raw); err == nil {
			t.Fatalf("accepted owners %s", raw)
		}
	}
	handler, err := sys.store.ManagementHandler(`["owner@example.com"]`)
	if err != nil {
		t.Fatal(err)
	}
	for _, headers := range []http.Header{{}, {"Tailscale-User-Login": {"listener@example.com"}}, {"Tailscale-User-Login": {"owner@example.com", "other"}}, {"Tailscale-User-Login": {"owner@example.com,other"}}, {"Tailscale-User-Login": {"owner@example.com"}, "Ts-Funnel-Request": {"?1"}}} {
		for _, path := range []string{"/manage/", "/manage/style.css", "/manage/manager.js"} {
			r := httptest.NewRequest("GET", path, nil)
			r.Header = headers
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != 403 {
				t.Fatalf("unauthorized %s: %d", path, w.Code)
			}
		}
	}
	for _, path := range []string{"/manage/", "/manage/style.css"} {
		r, err := http.NewRequest("GET", sys.server.URL+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		r.Header.Set("Tailscale-User-Login", "owner@example.com")
		response, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != 404 {
			t.Fatalf("public manager: %d", response.StatusCode)
		}
	}
	for _, headers := range []http.Header{{}, {"Origin": {"https://evil.example"}}, {"Sec-Fetch-Site": {"cross-site"}}} {
		r := httptest.NewRequest("POST", "/manage/", strings.NewReader("action=create&name=bad&csrf=bad"))
		r.Header = headers
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Tailscale-User-Login", "owner@example.com")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatalf("CSRF accepted: %d", w.Code)
		}
	}
	local, err := sys.store.LocalManagementHandler()
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	local.ServeHTTP(w, httptest.NewRequest("GET", "http://evil.example:8082/manage/", nil))
	if w.Code != 403 {
		t.Fatal("local host boundary")
	}
}

func makeUpload(t *testing.T, names []string, data [][]byte) (*http.Request, func()) {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	for i, name := range names {
		part, err := writer.CreateFormFile("files", name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := part.Write(data[i]); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("POST", "/manage/", &body)
	r.Header.Set("Content-Type", writer.FormDataContentType())
	if err := r.ParseMultipartForm(1 << 20); err != nil {
		t.Fatal(err)
	}
	return r, func() { r.MultipartForm.RemoveAll() }
}

func TestUploadsSharedLibraryStreamingAndAtomicFailure(t *testing.T) {
	sys := newTestSystem(t)
	token, cid, _, _ := sys.inviteAndPair(t)
	ctx := context.Background()
	audio, err := os.ReadFile("testdata/silence.mp3")
	if err != nil {
		t.Fatal(err)
	}
	r, cleanup := makeUpload(t, []string{"My song.mp3"}, [][]byte{audio})
	defer cleanup()
	if err := sys.store.UploadSongs(ctx, r.MultipartForm.File["files"], ""); err != nil {
		t.Fatal(err)
	}
	tracks, err := sys.store.libraryTracks(ctx, "My song")
	if err != nil || len(tracks) != 1 {
		t.Fatalf("library-only upload: %+v %v", tracks, err)
	}
	tid := tracks[0].ID
	session, err := sys.store.Authenticate(ctx, token)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := sys.store.TrackForRecipient(ctx, session.RecipientID, tid); err != ErrNotFound {
		t.Fatalf("library-only upload leaked to recipient: %v", err)
	}
	r2, cleanup2 := makeUpload(t, []string{"Same song.mp3"}, [][]byte{audio})
	defer cleanup2()
	if err := sys.store.UploadSongs(ctx, r2.MultipartForm.File["files"], cid); err != nil {
		t.Fatal(err)
	}
	if _, err := sys.scanner.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	tracks, err = sys.store.libraryTracks(ctx, "")
	if err != nil || len(tracks) != 3 {
		t.Fatalf("dedup or scanner: %+v %v", tracks, err)
	}
	detail, err := sys.store.CollectionDetail(ctx, session.RecipientID, cid)
	if err != nil || len(detail.Tracks) != 2 {
		t.Fatalf("uploaded playlist entry: %+v %v", detail, err)
	}
	req, _ := http.NewRequest("POST", sys.server.URL+"/v1/tracks/"+tid+"/play-url", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var play PlayURL
	err = json.NewDecoder(response.Body).Decode(&play)
	response.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	response, err = http.Get(play.URL)
	if err != nil {
		t.Fatal(err)
	}
	actual, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != 200 || !bytes.Equal(actual, audio) {
		t.Fatalf("uploaded stream: %d %v", response.StatusCode, err)
	}
	bad, cleanBad := makeUpload(t, []string{"Good.mp3", "Bad.mp3"}, [][]byte{append(append([]byte{}, audio...), audio...), []byte("not audio")})
	defer cleanBad()
	if err := sys.store.UploadSongs(ctx, bad.MultipartForm.File["files"], cid); err != ErrUpload {
		t.Fatalf("invalid MP3 accepted: %v", err)
	}
	missing, cleanMissing := makeUpload(t, []string{"Good.mp3"}, [][]byte{audio})
	defer cleanMissing()
	if err := sys.store.UploadSongs(ctx, missing.MultipartForm.File["files"], "missing"); err != ErrNotFound {
		t.Fatalf("missing destination: %v", err)
	}
	tracks, err = sys.store.libraryTracks(ctx, "")
	if err != nil || len(tracks) != 3 {
		t.Fatal("failed batch changed library")
	}
	entries, err := os.ReadDir(filepath.Join(sys.dataDir, "uploads"))
	if err != nil || len(entries) != 1 {
		t.Fatalf("staged files not cleaned: %+v %v", entries, err)
	}
	if err := sys.store.RemovePlaylistTrack(ctx, cid, tid); err != nil {
		t.Fatal(err)
	}
	response, err = http.Get(play.URL)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 404 {
		t.Fatalf("stream survived revoked membership: %d", response.StatusCode)
	}
}

func TestPlaylistMigrationPreservesIDsNotesAndOrder(t *testing.T) {
	dir := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(dir, "museek.db"))
	if err != nil {
		t.Fatal(err)
	}
	// A pre-manager database with the schema and notes used by released apps.
	_, err = db.Exec(`PRAGMA foreign_keys=ON;
 CREATE TABLE collections(id TEXT PRIMARY KEY,relative_path TEXT NOT NULL UNIQUE,name TEXT NOT NULL,artwork_id TEXT NOT NULL DEFAULT '',seen_at INTEGER NOT NULL,scanned_at INTEGER NOT NULL);
 CREATE TABLE tracks(id TEXT PRIMARY KEY,collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,relative_path TEXT NOT NULL UNIQUE,file_size INTEGER NOT NULL,file_mtime_ns INTEGER NOT NULL,title TEXT NOT NULL,artist TEXT NOT NULL DEFAULT '',album TEXT NOT NULL DEFAULT '',disc_number INTEGER NOT NULL DEFAULT 0,track_number INTEGER NOT NULL DEFAULT 0,duration_ms INTEGER NOT NULL DEFAULT 0,artwork_id TEXT NOT NULL DEFAULT '',seen_at INTEGER NOT NULL);
 CREATE UNIQUE INDEX tracks_collection_entry_idx ON tracks(collection_id,id);
 CREATE TABLE track_notes(collection_id TEXT NOT NULL,track_id TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(collection_id,track_id),FOREIGN KEY(collection_id,track_id) REFERENCES tracks(collection_id,id) ON DELETE CASCADE);
 INSERT INTO collections VALUES('old','Old playlist','Old playlist','',1,1);
 INSERT INTO tracks(id,collection_id,relative_path,file_size,file_mtime_ns,title,track_number,seen_at) VALUES('second','old','Old playlist/b.mp3',1,1,'Second',2,1),('first','old','Old playlist/a.mp3',1,1,'First',1,1);
 INSERT INTO track_notes VALUES('old','first','Keep this note');`)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	tracks, err := store.noteTracks(context.Background(), "old")
	if err != nil || len(tracks) != 2 || tracks[0].ID != "first" || tracks[0].Note != "Keep this note" {
		t.Fatalf("migration lost data: %+v %v", tracks, err)
	}
	if err := store.RemovePlaylistTrack(context.Background(), "old", "first"); err != nil {
		t.Fatal(err)
	}
	store.Close()
	store, err = OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	tracks, err = store.noteTracks(context.Background(), "old")
	if err != nil || len(tracks) != 1 || tracks[0].ID != "second" {
		t.Fatalf("reopening repeated migration: %+v %v", tracks, err)
	}
	var violations int
	rows, err := store.db.Query("PRAGMA foreign_key_check")
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		violations++
	}
	rows.Close()
	if violations != 0 {
		t.Fatal("migration left broken foreign keys")
	}
}

func TestManagerMultipartUploadForm(t *testing.T) {
	sys := newTestSystem(t)
	sys.inviteAndPair(t)
	handler, err := sys.store.LocalManagementHandler()
	if err != nil {
		t.Fatal(err)
	}
	get := httptest.NewRecorder()
	handler.ServeHTTP(get, httptest.NewRequest("GET", "http://127.0.0.1:8082/manage/", nil))
	match := regexp.MustCompile(`name="csrf" value="([^"]+)"`).FindStringSubmatch(get.Body.String())
	if len(match) != 2 {
		t.Fatal("missing token")
	}
	audio, err := os.ReadFile("testdata/silence.mp3")
	if err != nil {
		t.Fatal(err)
	}
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	for key, value := range map[string]string{"csrf": match[1], "action": "upload", "collection": ""} {
		if err := writer.WriteField(key, value); err != nil {
			t.Fatal(err)
		}
	}
	part, err := writer.CreateFormFile("files", "From laptop.mp3")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write(audio); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("POST", "http://127.0.0.1:8082/manage/", &body)
	r.Header.Set("Content-Type", writer.FormDataContentType())
	r.Header.Set("Origin", "http://127.0.0.1:8082")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 303 {
		t.Fatalf("upload form: %d %s", w.Code, w.Body.String())
	}
	tracks, err := sys.store.libraryTracks(context.Background(), "From laptop")
	if err != nil || len(tracks) != 1 {
		t.Fatalf("form upload did not reach library: %+v %v", tracks, err)
	}
}
