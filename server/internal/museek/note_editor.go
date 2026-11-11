package museek

import (
	"crypto/subtle"
	"errors"
	"html/template"
	"net"
	"net/http"
	"net/url"
)

// NoteEditorHandler is for a separate loopback-only owner listener, never the public API.
func (s *Store) NoteEditorHandler() (http.Handler, error) {
	token, err := randomToken(32)
	if err != nil {
		return nil, err
	}
	page := template.Must(template.New("notes").Parse(noteEditorHTML))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil || (host != "127.0.0.1" && host != "localhost" && host != "::1") {
			http.Error(w, "Local access only", http.StatusForbidden)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		if r.Method == http.MethodPost {
			r.Body = http.MaxBytesReader(w, r.Body, 256<<10)
			if err := r.ParseForm(); err != nil {
				http.Error(w, "Invalid form", http.StatusBadRequest)
				return
			}
			if subtle.ConstantTimeCompare([]byte(r.PostForm.Get("csrf")), []byte(token)) != 1 {
				http.Error(w, "Invalid form token", http.StatusForbidden)
				return
			}
			collectionID := r.PostForm.Get("collection")
			err := s.SetTrackNote(r.Context(), collectionID, r.PostForm.Get("track"), r.PostForm.Get("note"))
			if errors.Is(err, ErrNotFound) {
				http.Error(w, "This song is no longer in this playlist. Reload and try again.", http.StatusNotFound)
				return
			}
			if errors.Is(err, ErrNoteTooLong) {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			if err != nil {
				http.Error(w, "Could not save note", http.StatusInternalServerError)
				return
			}
			http.Redirect(w, r, "/?"+url.Values{"collection": {collectionID}, "saved": {r.PostForm.Get("track")}}.Encode(), http.StatusSeeOther)
			return
		}
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET, POST")
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		collections, err := s.noteCollections(r.Context())
		if err != nil {
			http.Error(w, "Could not load playlists", 500)
			return
		}
		collectionID := r.URL.Query().Get("collection")
		if collectionID == "" && len(collections) > 0 {
			collectionID = collections[0].ID
		}
		tracks, err := s.noteTracks(r.Context(), collectionID)
		if err != nil {
			http.Error(w, "Could not load songs", 500)
			return
		}
		data := struct {
			Collections           []Collection
			Tracks                []Track
			Selected, CSRF, Saved string
		}{collections, tracks, collectionID, token, r.URL.Query().Get("saved")}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = page.Execute(w, data)
	}), nil
}

const noteEditorHTML = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Museek · Song notes</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f4f2ed;color:#30372e;font:16px system-ui}main{max-width:760px;margin:50px auto;padding:0 24px}small{color:#757c6d}h1{font:40px Georgia;margin-bottom:12px}p{line-height:1.6;color:#72796b}nav{display:flex;gap:8px;flex-wrap:wrap;margin:28px 0}a{color:#6b40d1;text-decoration:none;padding:10px 14px;border-radius:12px;background:#e7e3ed}a[aria-current=page]{background:#6b40d1;color:white}article{background:#fffdf6;padding:24px;border-radius:18px;margin:16px 0}h2{margin:0 0 5px;font-size:19px}label{display:block;font-size:13px;margin:18px 0 8px}textarea{display:block;width:100%;min-height:130px;resize:vertical;padding:14px;border:1px solid #d9d9cd;border-radius:10px;background:#f7f6ef;font:17px Georgia;line-height:1.5}button{padding:11px 18px;background:#6b40d1;color:white;border:0;border-radius:10px;font:inherit;margin-top:14px;cursor:pointer}.saved{color:#4f7047;margin-left:12px}footer{font-size:12px;color:#808574;margin:26px 0}
</style><main><small>MUSEEK / YOUR PLAYLISTS</small><h1>A little something from you.</h1><p>Add an optional note to a song in this playlist. Leave it empty to remove it.<br>The same song in another playlist has its own note.</p>
<nav aria-label="Playlists">{{range .Collections}}<a href="?collection={{.ID}}" {{if eq .ID $.Selected}}aria-current="page"{{end}}>{{.Name}}</a>{{else}}<p>No playlists yet. Add a music folder and scan it first.</p>{{end}}</nav>
{{range .Tracks}}<article><h2>{{.Title}}</h2><small>{{.Artist}}</small><form method="post" action="/">
<input type="hidden" name="csrf" value="{{$.CSRF}}"><input type="hidden" name="collection" value="{{.CollectionID}}"><input type="hidden" name="track" value="{{.ID}}">
<label for="note-{{.ID}}">Your note · optional</label><textarea id="note-{{.ID}}" name="note" maxlength="10000" placeholder="What made you think of this song?">{{.Note}}</textarea><button type="submit">Save note</button>{{if eq $.Saved .ID}}<span class="saved" role="status">Saved</span>{{end}}</form></article>{{end}}
<footer>Notes stay with this playlist entry. Removing the song removes its note.</footer></main></html>`
