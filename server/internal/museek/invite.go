package museek

import (
	"io"
	"net/http"
)

func (a *API) inviteLanding(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = io.WriteString(w, inviteLandingHTML)
}

const inviteLandingHTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Open Museek</title>
  <style>
    :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #f9f7fc; color: #211a2d; }
    main { box-sizing: border-box; width: min(100%, 30rem); padding: 2rem; text-align: center; }
    .mark { width: 4.5rem; height: 4.5rem; margin: 0 auto 1.5rem; display: grid; place-items: center; border-radius: 50%; background: #eaddff; font-size: 2rem; }
    h1 { margin: 0 0 .75rem; font-size: 2rem; }
    p { margin: 0 0 1.5rem; color: #625b69; line-height: 1.5; }
    a { display: block; padding: 1rem 1.25rem; border-radius: 1rem; background: #6746d7; color: white; font-weight: 700; text-decoration: none; }
    a[hidden] { display: none; }
  </style>
</head>
<body>
  <main>
    <div class="mark" aria-hidden="true">♫</div>
    <h1>Open your music</h1>
    <p id="status">Opening Museek…</p>
    <a id="open" hidden>Open in Museek</a>
  </main>
  <script>
    (() => {
      const status = document.getElementById('status');
      const open = document.getElementById('open');
      const code = new URLSearchParams(window.location.hash.slice(1)).get('code');
      if (!code) {
        status.textContent = 'This invitation link is incomplete. Ask for a new one.';
        return;
      }
      const target = new URL('museek://pair');
      const basePath = window.location.pathname.replace(/\/invite\/?$/, '');
      target.searchParams.set('server', window.location.origin + basePath);
      target.searchParams.set('code', code);
      open.href = target.toString();
      open.hidden = false;
      window.setTimeout(() => window.location.assign(target.toString()), 150);
    })();
  </script>
</body>
</html>`
