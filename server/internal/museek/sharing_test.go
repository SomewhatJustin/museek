package museek

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

func shareRequest(t *testing.T, s *testSystem, path, bearer string, body any, want int) []byte {
	t.Helper()
	data, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", s.server.URL+path, bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	result, _ := io.ReadAll(res.Body)
	if res.StatusCode != want {
		t.Fatalf("%s: status %d want %d: %s", path, res.StatusCode, want, result)
	}
	return result
}

func playlistToken(t *testing.T, s *testSystem, bearer, collection string) string {
	t.Helper()
	body := shareRequest(t, s, "/v1/collections/"+collection+"/share", bearer, nil, 201)
	var result struct {
		URL       string    `json:"url"`
		ExpiresAt time.Time `json:"expiresAt"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	link, err := url.Parse(result.URL)
	if err != nil {
		t.Fatal(err)
	}
	fragment, _ := url.ParseQuery(link.Fragment)
	token := fragment.Get("playlist")
	if link.Path != "/invite" || link.RawQuery != "" || len(token) != 43 || time.Until(result.ExpiresAt) < 23*time.Hour {
		t.Fatalf("bad invitation URL or expiry")
	}
	if strings.Contains(s.logs.String(), token) {
		t.Fatal("share token leaked into logs")
	}
	return token
}

func TestPlaylistLinkAddsOnlySelectedPlaylistToNewAndExistingListeners(t *testing.T) {
	s := newTestSystem(t)
	owner, collection, _, _ := s.inviteAndPair(t)
	shareRequest(t, s, "/v1/collections/"+collection+"/share", "", nil, 401)
	privateID, _ := s.store.collectionIDByName(context.Background(), "Private Collection")
	shareRequest(t, s, "/v1/collections/"+privateID+"/share", owner, nil, 404)
	token := playlistToken(t, s, owner, collection)
	body := shareRequest(t, s, "/v1/playlist-links/redeem", "", map[string]string{"token": token, "deviceName": "New iPhone"}, 200)
	var result struct {
		CollectionID string     `json:"collectionId"`
		Session      PairResult `json:"session"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	session, err := s.store.Authenticate(context.Background(), result.Session.Token)
	if err != nil || result.CollectionID != collection {
		t.Fatal("new listener was not paired to playlist", err)
	}
	list, _ := s.store.ListCollections(context.Background(), session.RecipientID)
	if len(list) != 1 || list[0].ID != collection {
		t.Fatal("new listener received unrelated grants", list)
	}
	// An already paired listener keeps its session and prior collection.
	code, err := s.store.CreateInvite(context.Background(), "Other Listener", "Private Collection", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	other, err := s.store.Pair(context.Background(), code, "Other iPhone")
	if err != nil {
		t.Fatal(err)
	}
	for range 2 {
		data := shareRequest(t, s, "/v1/playlist-links/redeem", other.Token, map[string]string{"token": token}, 200)
		if strings.Contains(string(data), "\"session\"") {
			t.Fatal("existing session was replaced")
		}
	}
	list, _ = s.store.ListCollections(context.Background(), other.Recipient.ID)
	if len(list) != 2 {
		t.Fatal("existing grants lost or duplicate playlist added", list)
	}
	if strings.Contains(s.logs.String(), token) {
		t.Fatal("redemption token leaked into logs")
	}
}

func TestPlaylistLinkRejectsExpiredRevokedAndUnsharedInvitations(t *testing.T) {
	for _, change := range []string{"expired", "revoked", "unshared", "deleted"} {
		t.Run(change, func(t *testing.T) {
			s := newTestSystem(t)
			owner, collection, _, _ := s.inviteAndPair(t)
			token := playlistToken(t, s, owner, collection)
			switch change {
			case "expired":
				_, _ = s.store.db.Exec(`UPDATE playlist_links SET expires_at=0`)
			case "revoked":
				_, _ = s.store.db.Exec(`UPDATE device_sessions SET revoked_at=1`)
			case "unshared":
				_, _ = s.store.db.Exec(`DELETE FROM grants`)
			case "deleted":
				_, _ = s.store.db.Exec(`DELETE FROM collections WHERE id=?`, collection)
			}
			shareRequest(t, s, "/v1/playlist-links/redeem", "", map[string]string{"token": token}, 404)
			var n int
			_ = s.store.db.QueryRow(`SELECT COUNT(*) FROM recipients`).Scan(&n)
			if n != 1 {
				t.Fatal("failed redemption created a listener")
			}
		})
	}
}

func TestPlaylistLinkInvalidBearerDoesNotFallBackToAnonymousPairing(t *testing.T) {
	s := newTestSystem(t)
	owner, collection, _, _ := s.inviteAndPair(t)
	token := playlistToken(t, s, owner, collection)
	shareRequest(t, s, "/v1/playlist-links/redeem", "invalid", map[string]string{"token": token}, 401)
	shareRequest(t, s, "/v1/playlist-links/redeem", "", map[string]string{"token": "short"}, 400)
	shareRequest(t, s, "/v1/playlist-links/redeem", "", map[string]string{"token": strings.Repeat("x", 43)}, 404)
}
