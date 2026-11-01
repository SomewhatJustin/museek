package museek

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTailnetBoundaryAndGrants(t *testing.T) {
	s := newTestSystem(t)
	s.inviteAndPair(t)
	signer, _ := LoadStreamSigner(s.dataDir)
	api, _ := NewAPI(s.store, signer, s.musicDir, "", nil)
	private, err := api.TailnetHandler(`{"listener@example.com":"Listener"}`)
	if err != nil {
		t.Fatal(err)
	}
	request := func(h http.Handler, method, path string, headers http.Header) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(`{"deviceName":"Tailnet iPhone"}`))
		r.Header = headers
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	identity := http.Header{"Tailscale-User-Login": {"listener@example.com"}}
	for _, spec := range []struct{ method, path string }{{"GET", "/v1/server"}, {"POST", "/v1/tailnet/join"}} {
		if w := request(api.Handler(), spec.method, spec.path, identity); w.Code != 404 {
			t.Fatalf("public mounted %s: %d", spec.path, w.Code)
		}
	}
	for _, headers := range []http.Header{{}, {"Tailscale-User-Login": {"unknown@example.com"}}, {"Tailscale-User-Login": {"listener@example.com", "other@example.com"}}, {"Tailscale-User-Login": {"listener@example.com,other@example.com"}}, {"Tailscale-User-Login": {"listener@example.com"}, "Ts-Funnel-Request": {"?1"}}} {
		for _, spec := range []struct{ method, path string }{{"GET", "/v1/server"}, {"POST", "/v1/tailnet/join"}} {
			w := request(private, spec.method, spec.path, headers)
			if w.Code != 403 || strings.Contains(w.Body.String(), "token") {
				t.Fatalf("identity accepted: %d %s", w.Code, w.Body.String())
			}
		}
	}
	w := request(private, "GET", "/v1/server", identity)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"name":"Museek"`) {
		t.Fatalf("discovery: %d %s", w.Code, w.Body.String())
	}
	for i := 0; i < 5; i++ {
		w = request(private, "POST", "/v1/tailnet/join", identity)
		if w.Code != 201 {
			t.Fatalf("join: %d %s", w.Code, w.Body.String())
		}
		var pair PairResult
		if err := json.Unmarshal(w.Body.Bytes(), &pair); err != nil {
			t.Fatal(err)
		}
		session, err := s.store.Authenticate(context.Background(), pair.Token)
		if err != nil {
			t.Fatal(err)
		}
		collections, err := s.store.ListCollections(context.Background(), session.RecipientID)
		if err != nil || len(collections) != 1 || collections[0].Name != "Bedtime Favorites" {
			t.Fatalf("grant leak: %+v %v", collections, err)
		}
		if err := s.store.RevokeDevice(context.Background(), session.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := s.store.Authenticate(context.Background(), pair.Token); err == nil {
			t.Fatal("revoked token accepted")
		}
	}
	if w = request(private, "POST", "/v1/tailnet/join", identity); w.Code != 429 {
		t.Fatalf("missing limit: %d", w.Code)
	}
}

func TestTailnetMappingValidation(t *testing.T) {
	s := newTestSystem(t)
	s.inviteAndPair(t)
	signer, _ := LoadStreamSigner(s.dataDir)
	api, _ := NewAPI(s.store, signer, s.musicDir, "", nil)
	for _, raw := range []string{"", `null`, `[]`, `{}`, `{"a":"Missing"}`, `{"":"Listener"}`, `{"a":"Listener","a":"Listener"}`, `{"a":"Listener"} {}`} {
		if _, err := api.TailnetHandler(raw); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
}
