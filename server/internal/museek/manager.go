package museek

import (
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"html/template"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
)

//go:embed web/*
var managerFiles embed.FS

// ManagementHandler belongs on a separate trusted Tailscale Serve upstream.
// Every request, including assets, requires an explicitly allowed owner identity.
func (s *Store) ManagementHandler(raw string) (http.Handler, error) {
	var logins []string
	decoder := json.NewDecoder(strings.NewReader(raw))
	if err := decoder.Decode(&logins); err != nil {
		return nil, errors.New("manage users must be a JSON array of exact Tailscale owner logins")
	}
	if err := decoder.Decode(new(any)); err != io.EOF || len(logins) == 0 {
		return nil, errors.New("manage users must be a nonempty JSON array")
	}
	owners := map[string]bool{}
	for _, login := range logins {
		if login == "" || strings.TrimSpace(login) != login || strings.ContainsAny(login, ",\r\n") || owners[login] {
			return nil, errors.New("invalid or duplicate manage login")
		}
		owners[login] = true
	}
	handler, err := s.managerHandler()
	if err != nil {
		return nil, err
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		values := r.Header.Values("Tailscale-User-Login")
		_, funnel := r.Header[http.CanonicalHeaderKey("Ts-Funnel-Request")]
		if funnel || len(values) != 1 || !owners[values[0]] {
			http.Error(w, "This Tailscale account cannot manage Museek.", 403)
			return
		}
		handler.ServeHTTP(w, r)
	}), nil
}

// LocalManagementHandler supports development and an SSH port-forward without
// treating user-supplied identity headers as authentication on a network port.
func (s *Store) LocalManagementHandler() (http.Handler, error) {
	handler, err := s.managerHandler()
	if err != nil {
		return nil, err
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil || (host != "127.0.0.1" && host != "localhost" && host != "::1") {
			http.Error(w, "Local access only", 403)
			return
		}
		handler.ServeHTTP(w, r)
	}), nil
}

type managerRecipient struct{ ID, Name string }
type managerPage struct {
	CSRF, Selected, Title, Query, Message string
	Collections                           []Collection
	Tracks, Library                       []Track
	Recipients                            []managerRecipient
	Adding                                bool
}

func (s *Store) managerHandler() (http.Handler, error) {
	token, err := randomToken(32)
	if err != nil {
		return nil, err
	}
	page, err := template.New("manager.html").Funcs(template.FuncMap{"lastIndex": func(tracks []Track) int { return len(tracks) - 1 }}).ParseFS(managerFiles, "web/manager.html")
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /manage", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/manage/", 303) })
	for _, asset := range []struct{ name, contentType string }{{"style.css", "text/css; charset=utf-8"}, {"manager.js", "text/javascript; charset=utf-8"}} {
		data, err := managerFiles.ReadFile("web/" + asset.name)
		if err != nil {
			return nil, err
		}
		mux.HandleFunc("GET /manage/"+asset.name, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", asset.contentType)
			w.Write(data)
		})
	}
	mux.HandleFunc("GET /manage/{$}", func(w http.ResponseWriter, r *http.Request) {
		collections, err := s.noteCollections(r.Context())
		if err != nil {
			http.Error(w, "Could not load playlists", 500)
			return
		}
		p := managerPage{CSRF: token, Selected: r.URL.Query().Get("collection"), Query: r.URL.Query().Get("q"), Collections: collections, Title: "Library", Adding: r.URL.Query().Get("add") == "1"}
		if r.URL.Query().Get("saved") == "1" {
			p.Message = "Saved."
		}
		if p.Selected != "" {
			found := false
			for _, c := range collections {
				if c.ID == p.Selected {
					p.Title = c.Name
					found = true
				}
			}
			if !found {
				http.Error(w, "Playlist not found", 404)
				return
			}
			p.Tracks, err = s.noteTracks(r.Context(), p.Selected)
			if err != nil {
				http.Error(w, "Could not load playlist", 500)
				return
			}
		}
		if p.Selected == "" || p.Adding {
			p.Library, err = s.libraryTracks(r.Context(), p.Query)
			if err != nil {
				http.Error(w, "Could not load library", 500)
				return
			}
			if p.Adding {
				present := map[string]bool{}
				for _, t := range p.Tracks {
					present[t.ID] = true
				}
				available := []Track{}
				for _, t := range p.Library {
					if !present[t.ID] {
						available = append(available, t)
					}
				}
				p.Library = available
			}
		}
		rows, err := s.db.QueryContext(r.Context(), "SELECT id,name FROM recipients ORDER BY name COLLATE NOCASE")
		if err != nil {
			http.Error(w, "Could not load listeners", 500)
			return
		}
		for rows.Next() {
			var recipient managerRecipient
			if err := rows.Scan(&recipient.ID, &recipient.Name); err != nil {
				rows.Close()
				http.Error(w, "Could not load listeners", 500)
				return
			}
			p.Recipients = append(p.Recipients, recipient)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			http.Error(w, "Could not load listeners", 500)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := page.Execute(w, p); err != nil {
			return
		}
	})
	mux.HandleFunc("POST /manage/{$}", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 512<<20)
		if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
			if err := r.ParseMultipartForm(1 << 20); err != nil {
				if r.MultipartForm != nil {
					r.MultipartForm.RemoveAll()
				}
				http.Error(w, "Upload too large or invalid. Maximum selection: 512 MB; maximum song: 128 MB.", 400)
				return
			}
			defer r.MultipartForm.RemoveAll()
		} else {
			r.Body = http.MaxBytesReader(w, r.Body, 256<<10)
			if err := r.ParseForm(); err != nil {
				http.Error(w, "Invalid form", 400)
				return
			}
		}
		if subtle.ConstantTimeCompare([]byte(r.PostForm.Get("csrf")), []byte(token)) != 1 {
			http.Error(w, "This form expired. Reload Museek and try again.", 403)
			return
		}
		cid := r.PostForm.Get("collection")
		var err error
		switch r.PostForm.Get("action") {
		case "create":
			cid, err = s.CreatePlaylist(r.Context(), r.PostForm.Get("name"), r.PostForm.Get("recipient"))
		case "note":
			err = s.SetTrackNote(r.Context(), cid, r.PostForm.Get("track"), r.PostForm.Get("note"))
		case "remove":
			err = s.RemovePlaylistTrack(r.Context(), cid, r.PostForm.Get("track"))
		case "up", "down":
			err = s.MovePlaylistTrack(r.Context(), cid, r.PostForm.Get("track"), r.PostForm.Get("action"))
		case "add":
			err = s.AddPlaylistTracks(r.Context(), cid, r.PostForm["tracks"])
		case "upload":
			if r.MultipartForm == nil {
				err = ErrUpload
			} else {
				err = s.UploadSongs(r.Context(), r.MultipartForm.File["files"], cid)
			}
		default:
			err = ErrPlaylistInput
		}
		if err != nil {
			switch {
			case errors.Is(err, ErrNotFound):
				http.Error(w, "This playlist or song has changed. Go back and reload before trying again.", 404)
			case errors.Is(err, ErrPlaylistInput):
				http.Error(w, "Enter a playlist name and listener, or select songs to add. Go back to try again.", 400)
			case errors.Is(err, ErrUpload), errors.Is(err, ErrNoteTooLong):
				http.Error(w, err.Error()+". Go back to try again.", 400)
			default:
				http.Error(w, "Could not save changes. Go back to try again.", 500)
			}
			return
		}
		location := "/manage/?" + url.Values{"collection": {cid}, "saved": {"1"}}.Encode()
		if track := r.PostForm.Get("track"); track != "" && r.PostForm.Get("action") != "remove" {
			location += "#track-" + url.PathEscape(track)
		}
		http.Redirect(w, r, location, 303)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "same-origin")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; script-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		if r.Method != "GET" && r.Method != "HEAD" {
			origin := r.Header.Get("Origin")
			if origin != "" {
				parsed, err := url.Parse(origin)
				if err != nil || parsed.Host != r.Host || (parsed.Scheme != "https" && parsed.Scheme != "http") {
					http.Error(w, "Cross-origin request rejected", 403)
					return
				}
			}
			if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
				http.Error(w, "Cross-site request rejected", 403)
				return
			}
		}
		mux.ServeHTTP(w, r)
	}), nil
}
