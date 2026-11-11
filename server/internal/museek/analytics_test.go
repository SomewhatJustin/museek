package museek

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPlaylistListenValidationAndIsolation(t *testing.T) {
	sys := newTestSystem(t)
	token, cid, tid, _ := sys.inviteAndPair(t)
	ctx := context.Background()
	session, err := sys.store.Authenticate(ctx, token)
	if err != nil {
		t.Fatal(err)
	}
	other, err := sys.store.CreatePlaylist(ctx, "Another playlist", session.RecipientID)
	if err != nil {
		t.Fatal(err)
	}
	if err := sys.store.AddPlaylistTracks(ctx, other, []string{tid}); err != nil {
		t.Fatal(err)
	}
	private, err := sys.store.collectionIDByName(ctx, "Private Collection")
	if err != nil {
		t.Fatal(err)
	}
	// Access to a song via one playlist must not authorize reporting it in another.
	if err := sys.store.AddPlaylistTracks(ctx, private, []string{tid}); err != nil {
		t.Fatal(err)
	}
	post := func(collection, bearer, body string, want int) {
		t.Helper()
		req, _ := http.NewRequest("POST", sys.server.URL+"/v1/collections/"+collection+"/listens", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != want {
			t.Fatalf("listen %s: got %d, want %d", body, response.StatusCode, want)
		}
	}
	body := func(id, client string, ms int64) string {
		b, _ := json.Marshal(Listen{ID: id, TrackID: tid, Client: client, ListenedMS: ms})
		return string(b)
	}
	for _, ms := range []int64{-1, 0, 29999, 30000} {
		post(cid, token, body("short", "iphone", ms), 400)
	}
	for _, client := range []string{"", "web", "android", "iPad"} {
		post(cid, token, body("wrong-client", client, 31000), 400)
	}
	post(cid, token, body("", "iphone", 31000), 400)
	post(cid, token, `{"id":"e","trackId":"`+tid+`","client":"iphone","listenedMs":31000,"unexpected":true}`, 400)
	post(cid, "", body("no-session", "iphone", 31000), 401)
	post(private, token, body("private", "iphone", 31000), 404)
	post("missing", token, body("missing", "iphone", 31000), 404)
	post(cid, token, `{"id":"missing-track","trackId":"missing","client":"iphone","listenedMs":31000}`, 404)
	// Both issuing a URL and fetching audio (including a download) are read-only.
	req, _ := http.NewRequest("POST", sys.server.URL+"/v1/tracks/"+tid+"/play-url", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var play PlayURL
	if err := json.NewDecoder(response.Body).Decode(&play); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	response, err = http.Get(play.URL)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if getDetail(t, sys.server.URL, token, cid).Tracks[0].PlayCount != 0 {
		t.Fatal("stream or download counted as play")
	}
	post(cid, token, body("first", "iphone", 30001), 200)
	post(cid, token, body("first", "iphone", 30001), 200)
	post(cid, token, body("replay", "iphone", 45000), 200)
	post(other, token, body("other", "iphone", 31000), 200)
	post(other, token, body("first", "iphone", 31000), 400)
	if _, err := sys.scanner.Scan(ctx); err != nil {
		t.Fatal(err)
	}
	if got := getDetail(t, sys.server.URL, token, cid).Tracks[0].PlayCount; got != 2 {
		t.Fatalf("count after retry and scan: %d", got)
	}
	if got := getDetail(t, sys.server.URL, token, other).Tracks[0].PlayCount; got != 1 {
		t.Fatalf("other playlist count: %d", got)
	}
	// Existing data survives migration being run again and reopening the database.
	reopened, err := OpenStore(sys.dataDir)
	if err != nil {
		t.Fatal(err)
	}
	detail, err := reopened.CollectionDetail(ctx, session.RecipientID, cid)
	reopened.Close()
	if err != nil || detail.Tracks[0].PlayCount != 2 {
		t.Fatalf("reopen: %+v %v", detail, err)
	}
	handler, err := sys.store.LocalManagementHandler()
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("GET", "http://127.0.0.1:8081/manage/?collection="+cid, nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), "2 plays") {
		t.Fatalf("manager count missing: %d %s", w.Code, w.Body.String())
	}
	if err := sys.store.RevokeDevice(ctx, session.ID); err != nil {
		t.Fatal(err)
	}
	post(cid, token, body("revoked", "iphone", 31000), 401)
}

func TestListenCountsCombineListenersAndResetWithEntry(t *testing.T) {
	sys := newTestSystem(t)
	token, cid, tid, _ := sys.inviteAndPair(t)
	ctx := context.Background()
	original, err := sys.store.Authenticate(ctx, token)
	if err != nil {
		t.Fatal(err)
	}
	pair := func(name string) Session {
		t.Helper()
		code, err := sys.store.CreateInvite(ctx, name, "Bedtime Favorites", 0)
		if err != nil {
			t.Fatal(err)
		}
		result, err := sys.store.Pair(ctx, code, "Another iPhone")
		if err != nil {
			t.Fatal(err)
		}
		session, err := sys.store.Authenticate(ctx, result.Token)
		if err != nil {
			t.Fatal(err)
		}
		return session
	}
	record := func(session Session, id string) {
		t.Helper()
		if err := sys.store.RecordListen(ctx, session, cid, Listen{ID: id, TrackID: tid, Client: "iphone", ListenedMS: 31000}); err != nil {
			t.Fatal(err)
		}
	}
	record(original, "offline-from-first-phone")
	// Re-pairing to the same recipient must also be safe after a lost response.
	record(pair("Listener"), "offline-from-first-phone")
	second := pair("Second listener")
	record(second, "second-listener")
	detail, err := sys.store.CollectionDetail(ctx, original.RecipientID, cid)
	if err != nil || detail.Tracks[0].PlayCount != 2 {
		t.Fatalf("combined count: %+v %v", detail, err)
	}
	if err := sys.store.RecordListen(ctx, second, cid, Listen{ID: "offline-from-first-phone", TrackID: tid, Client: "iphone", ListenedMS: 31000}); err != ErrListenInput {
		t.Fatalf("event reused across listeners: %v", err)
	}
	if err := sys.store.RemovePlaylistTrack(ctx, cid, tid); err != nil {
		t.Fatal(err)
	}
	if err := sys.store.AddPlaylistTracks(ctx, cid, []string{tid}); err != nil {
		t.Fatal(err)
	}
	detail, err = sys.store.CollectionDetail(ctx, original.RecipientID, cid)
	if err != nil || detail.Tracks[0].PlayCount != 0 {
		t.Fatalf("removed entry retained counts: %+v %v", detail, err)
	}
}
