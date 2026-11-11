package museek

import "time"

type Collection struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	ArtworkID   string    `json:"artworkId,omitempty"`
	TrackCount  int       `json:"trackCount"`
	LastScanned time.Time `json:"lastScanned"`
}

type Track struct {
	Note         string `json:"note,omitempty"`
	ID           string `json:"id"`
	CollectionID string `json:"collectionId"`
	Title        string `json:"title"`
	Artist       string `json:"artist,omitempty"`
	Album        string `json:"album,omitempty"`
	DiscNumber   int    `json:"discNumber,omitempty"`
	TrackNumber  int    `json:"trackNumber,omitempty"`
	DurationMS   int64  `json:"durationMs,omitempty"`
	ArtworkID    string `json:"artworkId,omitempty"`
}

type CollectionDetail struct {
	Collection
	Tracks []Track `json:"tracks"`
}

type Device struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	CreatedAt time.Time  `json:"createdAt"`
	LastUsed  time.Time  `json:"lastUsed"`
	RevokedAt *time.Time `json:"revokedAt,omitempty"`
}

type Session struct {
	ID          string
	RecipientID string
	DeviceName  string
}

type TrackFile struct {
	Track
	RelativePath string
	ModifiedAt   time.Time
}

type PairResult struct {
	Token     string `json:"token"`
	Recipient struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"recipient"`
}

type PlayURL struct {
	URL       string    `json:"url"`
	ExpiresAt time.Time `json:"expiresAt"`
}
