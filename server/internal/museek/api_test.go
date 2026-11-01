package museek

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type testSystem struct {
	store      *Store
	scanner    *Scanner
	server     *httptest.Server
	musicDir   string
	dataDir    string
	trackBytes []byte
	logs       *bytes.Buffer
}

func newTestSystem(t *testing.T) *testSystem {
	t.Helper()
	root := t.TempDir()
	musicDir := filepath.Join(root, "music")
	dataDir := filepath.Join(root, "data")
	collection := filepath.Join(musicDir, "Bedtime Favorites")
	second := filepath.Join(musicDir, "Private Collection")
	if err := os.MkdirAll(collection, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(second, 0o700); err != nil {
		t.Fatal(err)
	}
	trackBytes := bytes.Repeat([]byte("museek-audio-"), 128)
	if err := os.WriteFile(filepath.Join(collection, "01 Lullaby.mp3"), trackBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	// Enough of a PNG signature for MIME detection; image decoding is a client concern.
	if err := os.WriteFile(filepath.Join(collection, "cover.png"), []byte("\x89PNG\r\n\x1a\nfixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(second, "Secret.mp3"), []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	scanner, err := NewScanner(store, musicDir)
	if err != nil {
		t.Fatal(err)
	}
	result, err := scanner.Scan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.Collections != 2 || result.Tracks != 2 {
		t.Fatalf("unexpected scan result: %+v", result)
	}
	signer, err := LoadStreamSigner(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	logs := &bytes.Buffer{}
	api, err := NewAPI(store, signer, musicDir, "", slog.New(slog.NewJSONHandler(logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(api.Handler())
	t.Cleanup(server.Close)
	return &testSystem{store: store, scanner: scanner, server: server, musicDir: musicDir, dataDir: dataDir, trackBytes: trackBytes, logs: logs}
}

func TestInviteLandingPage(t *testing.T) {
	system := newTestSystem(t)
	response, err := http.Get(system.server.URL + "/invite#code=SHOULD-NOT-REACH-SERVER")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("unexpected status: %d", response.StatusCode)
	}
	if response.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("invite page must not be cached: %q", response.Header.Get("Cache-Control"))
	}
	if !strings.Contains(string(body), "museek://pair") || !strings.Contains(string(body), "window.location.hash") {
		t.Fatalf("invite page does not bridge the fragment to Museek: %s", body)
	}
	if !strings.Contains(string(body), "window.location.pathname") || !strings.Contains(string(body), "basePath") {
		t.Fatalf("invite page does not preserve a reverse-proxy base path: %s", body)
	}
	if strings.Contains(system.logs.String(), "SHOULD-NOT-REACH-SERVER") {
		t.Fatal("URL fragment leaked into server access logs")
	}
}

func (s *testSystem) inviteAndPair(t *testing.T) (token, collectionID, trackID, artworkID string) {
	t.Helper()
	code, err := s.store.CreateInvite(context.Background(), "Listener", "Bedtime Favorites", 24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{"code": code, "deviceName": "Test iPhone"})
	response, err := http.Post(s.server.URL+"/v1/pair", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		data, _ := io.ReadAll(response.Body)
		t.Fatalf("pair status %d: %s", response.StatusCode, data)
	}
	var pair PairResult
	if err := json.NewDecoder(response.Body).Decode(&pair); err != nil {
		t.Fatal(err)
	}
	request, _ := http.NewRequest(http.MethodGet, s.server.URL+"/v1/collections", nil)
	request.Header.Set("Authorization", "Bearer "+pair.Token)
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var list struct {
		Collections []Collection `json:"collections"`
	}
	if err := json.NewDecoder(response.Body).Decode(&list); err != nil {
		t.Fatal(err)
	}
	if len(list.Collections) != 1 || list.Collections[0].Name != "Bedtime Favorites" {
		t.Fatalf("grant isolation failed: %+v", list.Collections)
	}
	collectionID = list.Collections[0].ID
	artworkID = list.Collections[0].ArtworkID
	detail := getDetail(t, s.server.URL, pair.Token, collectionID)
	if len(detail.Tracks) != 1 {
		t.Fatalf("expected one track, got %+v", detail.Tracks)
	}
	return pair.Token, collectionID, detail.Tracks[0].ID, artworkID
}

func getDetail(t *testing.T, baseURL, token, collectionID string) CollectionDetail {
	t.Helper()
	request, _ := http.NewRequest(http.MethodGet, baseURL+"/v1/collections/"+collectionID, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(response.Body)
		t.Fatalf("detail status %d: %s", response.StatusCode, data)
	}
	var detail CollectionDetail
	if err := json.NewDecoder(response.Body).Decode(&detail); err != nil {
		t.Fatal(err)
	}
	return detail
}

func authorizedRequest(t *testing.T, method, endpoint, token string) *http.Response {
	t.Helper()
	request, _ := http.NewRequest(method, endpoint, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func TestEndToEndPairBrowseStreamRevokeAndDelete(t *testing.T) {
	system := newTestSystem(t)
	token, collectionID, trackID, artworkID := system.inviteAndPair(t)

	unauthorized, err := http.Get(system.server.URL + "/v1/collections")
	if err != nil {
		t.Fatal(err)
	}
	unauthorized.Body.Close()
	if unauthorized.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unpaired list status = %d", unauthorized.StatusCode)
	}

	art := authorizedRequest(t, http.MethodGet, system.server.URL+"/v1/artwork/"+artworkID, token)
	artData, _ := io.ReadAll(art.Body)
	art.Body.Close()
	if art.StatusCode != http.StatusOK || !strings.HasPrefix(string(artData), "\x89PNG") {
		t.Fatalf("authorized artwork failed: %d %q", art.StatusCode, artData)
	}
	noArt, _ := http.Get(system.server.URL + "/v1/artwork/" + artworkID)
	noArt.Body.Close()
	if noArt.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unpaired artwork status = %d", noArt.StatusCode)
	}

	play := authorizedRequest(t, http.MethodPost, system.server.URL+"/v1/tracks/"+trackID+"/play-url", token)
	if play.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(play.Body)
		t.Fatalf("play URL status %d: %s", play.StatusCode, data)
	}
	var playURL PlayURL
	if err := json.NewDecoder(play.Body).Decode(&playURL); err != nil {
		t.Fatal(err)
	}
	play.Body.Close()
	if !strings.HasPrefix(playURL.URL, system.server.URL+"/v1/streams/") {
		t.Fatalf("unexpected play URL %q", playURL.URL)
	}

	stream, err := http.Get(playURL.URL)
	if err != nil {
		t.Fatal(err)
	}
	streamData, _ := io.ReadAll(stream.Body)
	stream.Body.Close()
	if stream.StatusCode != http.StatusOK || !bytes.Equal(streamData, system.trackBytes) {
		t.Fatalf("full stream failed: %d, %d bytes; logs: %s", stream.StatusCode, len(streamData), system.logs.String())
	}
	if stream.Header.Get("Content-Type") != "audio/mpeg" || stream.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("missing audio/range headers: %v", stream.Header)
	}

	rangeRequest, _ := http.NewRequest(http.MethodGet, playURL.URL, nil)
	rangeRequest.Header.Set("Range", "bytes=10-29")
	ranged, err := http.DefaultClient.Do(rangeRequest)
	if err != nil {
		t.Fatal(err)
	}
	rangedData, _ := io.ReadAll(ranged.Body)
	ranged.Body.Close()
	if ranged.StatusCode != http.StatusPartialContent || !bytes.Equal(rangedData, system.trackBytes[10:30]) {
		t.Fatalf("range stream failed: %d %q", ranged.StatusCode, rangedData)
	}

	parsed, _ := url.Parse(playURL.URL)
	streamToken := parsed.Query().Get("token")
	if strings.Contains(system.logs.String(), streamToken) {
		t.Fatal("signed stream token leaked into access logs")
	}

	devices, err := system.store.ListDevices(context.Background(), "Listener")
	if err != nil || len(devices) != 1 {
		t.Fatalf("list devices: %+v, %v", devices, err)
	}
	if err := system.store.RevokeDevice(context.Background(), devices[0].ID); err != nil {
		t.Fatal(err)
	}
	revoked := authorizedRequest(t, http.MethodGet, system.server.URL+"/v1/collections", token)
	revoked.Body.Close()
	if revoked.StatusCode != http.StatusUnauthorized {
		t.Fatalf("revoked session status = %d", revoked.StatusCode)
	}
	revokedStream, _ := http.Get(playURL.URL)
	revokedStream.Body.Close()
	if revokedStream.StatusCode != http.StatusUnauthorized {
		t.Fatalf("existing stream URL survived revocation: %d", revokedStream.StatusCode)
	}

	// Pair a replacement device, remove the source file, and prove rescanning revokes content.
	newCode, err := system.store.CreateInvite(context.Background(), "Listener", "Bedtime Favorites", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{"code": newCode, "deviceName": "Replacement"})
	pairResponse, _ := http.Post(system.server.URL+"/v1/pair", "application/json", bytes.NewReader(body))
	var replacement PairResult
	json.NewDecoder(pairResponse.Body).Decode(&replacement)
	pairResponse.Body.Close()
	if err := os.Remove(filepath.Join(system.musicDir, "Bedtime Favorites", "01 Lullaby.mp3")); err != nil {
		t.Fatal(err)
	}
	if _, err := system.scanner.Scan(context.Background()); err != nil {
		t.Fatal(err)
	}
	detail := getDetail(t, system.server.URL, replacement.Token, collectionID)
	if len(detail.Tracks) != 0 {
		t.Fatalf("deleted track remains indexed: %+v", detail.Tracks)
	}
	missing := authorizedRequest(t, http.MethodPost, system.server.URL+"/v1/tracks/"+trackID+"/play-url", replacement.Token)
	missing.Body.Close()
	if missing.StatusCode != http.StatusNotFound {
		t.Fatalf("deleted track play status = %d", missing.StatusCode)
	}
}

func TestPairingCodeReusableUntilExpiryAndRateLimited(t *testing.T) {
	system := newTestSystem(t)
	code, err := system.store.CreateInvite(context.Background(), "Listener", "Bedtime Favorites", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{"code": code, "deviceName": "First"})
	first, _ := http.Post(system.server.URL+"/v1/pair", "application/json", bytes.NewReader(body))
	first.Body.Close()
	if first.StatusCode != http.StatusCreated {
		t.Fatalf("first use status = %d", first.StatusCode)
	}
	second, _ := http.Post(system.server.URL+"/v1/pair", "application/json", bytes.NewReader(body))
	second.Body.Close()
	if second.StatusCode != http.StatusCreated {
		t.Fatalf("second use status = %d", second.StatusCode)
	}
	devices, err := system.store.ListDevices(context.Background(), "Listener")
	if err != nil || len(devices) != 2 {
		t.Fatalf("reusable code devices = %+v, %v", devices, err)
	}
	if _, err := system.store.db.ExecContext(
		context.Background(),
		`UPDATE pairing_codes SET expires_at = ? WHERE code_hash = ?`,
		nowUnix()-1,
		hashSecret(normalizeCode(code)),
	); err != nil {
		t.Fatal(err)
	}
	third, _ := http.Post(system.server.URL+"/v1/pair", "application/json", bytes.NewReader(body))
	third.Body.Close()
	if third.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expired code status = %d", third.StatusCode)
	}

	badBody := []byte(`{"code":"WRONG","deviceName":"Attacker"}`)
	var last int
	for i := 0; i < 5; i++ {
		response, _ := http.Post(system.server.URL+"/v1/pair", "application/json", bytes.NewReader(badBody))
		last = response.StatusCode
		response.Body.Close()
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("rate limit did not engage, final status = %d", last)
	}
}

func TestStorePersistsAcrossRestart(t *testing.T) {
	root := t.TempDir()
	dataDir := filepath.Join(root, "data")
	musicDir := filepath.Join(root, "music")
	if err := os.MkdirAll(filepath.Join(musicDir, "Bedtime Favorites"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(musicDir, "Bedtime Favorites", "Song.mp3"), []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	scanner, err := NewScanner(store, musicDir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := scanner.Scan(context.Background()); err != nil {
		t.Fatal(err)
	}
	code, err := store.CreateInvite(context.Background(), "Listener", "Bedtime Favorites", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := store.Pair(context.Background(), code, "Persistent iPhone")
	if err != nil {
		t.Fatal(err)
	}
	store.Close()
	reopened, err := OpenStore(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	session, err := reopened.Authenticate(context.Background(), pair.Token)
	if err != nil {
		t.Fatalf("saved session did not authenticate: %v", err)
	}
	collections, err := reopened.ListCollections(context.Background(), session.RecipientID)
	if err != nil {
		t.Fatal(err)
	}
	if len(collections) != 1 || collections[0].Name != "Bedtime Favorites" {
		t.Fatalf("saved grant did not persist: %+v", collections)
	}
}
