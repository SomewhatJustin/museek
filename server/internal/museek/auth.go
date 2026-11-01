package museek

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type StreamSigner struct {
	key []byte
}

type streamClaims struct {
	TrackID   string `json:"track"`
	SessionID string `json:"session"`
	Expires   int64  `json:"exp"`
}

func LoadStreamSigner(dataDir string) (*StreamSigner, error) {
	path := filepath.Join(dataDir, "signing.key")
	key, err := os.ReadFile(path)
	if err == nil {
		if len(key) != 32 {
			return nil, errors.New("signing key has invalid length")
		}
		return &StreamSigner{key: key}, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read signing key: %w", err)
	}
	key = make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		return LoadStreamSigner(dataDir)
	}
	if err != nil {
		return nil, fmt.Errorf("create signing key: %w", err)
	}
	if _, err := file.Write(key); err != nil {
		file.Close()
		return nil, err
	}
	if err := file.Close(); err != nil {
		return nil, err
	}
	return &StreamSigner{key: key}, nil
}

func (s *StreamSigner) Sign(trackID, sessionID string, expires time.Time) (string, error) {
	payload, err := json.Marshal(streamClaims{TrackID: trackID, SessionID: sessionID, Expires: expires.Unix()})
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, s.key)
	mac.Write([]byte(encoded))
	signature := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return encoded + "." + signature, nil
}

func (s *StreamSigner) Verify(token string, now time.Time) (streamClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return streamClaims{}, ErrUnauthorized
	}
	mac := hmac.New(sha256.New, s.key)
	mac.Write([]byte(parts[0]))
	expected := mac.Sum(nil)
	provided, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || !hmac.Equal(expected, provided) {
		return streamClaims{}, ErrUnauthorized
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return streamClaims{}, ErrUnauthorized
	}
	var claims streamClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return streamClaims{}, ErrUnauthorized
	}
	if claims.TrackID == "" || claims.SessionID == "" || claims.Expires <= now.Unix() {
		return streamClaims{}, ErrUnauthorized
	}
	return claims, nil
}
