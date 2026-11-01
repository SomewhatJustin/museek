# Private Tailscale discovery and joining

The native SwiftUI pairing screen checks the fixed HTTPS server
`https://elitedesk-1.tail6900fe.ts.net:10002/v1/server` without pairing or creating a
session. An authorized server shows **Museek found / Join Museek**. Only tapping
Join posts `/v1/tailnet/join`. Invitation fields remain available during detection,
after a timeout, and after a denied join. Nothing changes for invitation links.

## Trust boundary

The default `:8080` listener never registers either endpoint, regardless of
supplied identity headers. `MUSEEK_TAILNET_LISTEN` is unset/disabled by default.
Setting it (normally `:8081` in Docker) opts in to a separate listener. This
listener is trusted ingress: **only the local Tailscale Serve proxy may reach it**.
Headers are not authentication when callers can directly access that port.
Publish the Docker port on loopback only. Do not put this listener behind Funnel,
a public reverse proxy, or a directly reachable LAN port.

Both discovery and join require exactly one `Tailscale-User-Login` value matching
the configured login verbatim. Missing, duplicate, comma-combined, unauthorized
identity headers and any `Ts-Funnel-Request` marker are rejected. The endpoint
never accepts an identity, recipient, or collection from the request body.

`MUSEEK_TAILNET_USERS` is a JSON object mapping **exact Tailscale login → exact
existing Museek recipient display name**, for example (placeholder only):

```sh
MUSEEK_TAILNET_USERS='{"listener@example.com":"Existing Listener"}'
```

Unknown recipients, duplicate login keys, malformed JSON, null and empty mappings
fail startup when the listener is enabled. No recipients or grants are created.
The new random bearer session uses the normal hashed-token device session table,
existing recipient grants, and ordinary device revocation. Join attempts are
limited to 5 per mapped identity per 5 minutes (in-memory, resets on restart).
Discovery never creates sessions. Tagged Tailscale nodes without user identity
cannot join. Access logs omit headers, request bodies and bearer tokens.

## Deployment checklist (operator action; not automatically executed)

1. Determine the real Tailscale login and intended **existing** recipient securely;
   review that recipient's grants. Do not invent a mapping or grant all collections.
2. Build the updated server image. In the actual host Compose file, preserve the
   existing public `127.0.0.1:18080:8080` binding and public URL. Add
   `127.0.0.1:18081:8081`, `MUSEEK_TAILNET_LISTEN=:8081`, and the mapping JSON.
   `deploy/elitedesk-tailnet.compose.yaml` is an opt-in overlay example; combine it
   with `deploy/elitedesk.compose.yaml` only after setting the mapping.
3. Validate rendered Compose configuration and start the updated service. Invalid
   mappings must fail closed; check logs without printing identity configuration.
4. Change **only** private Tailscale Serve HTTPS port **10002** to upstream
   `http://127.0.0.1:18081`. Keep Funnel port 443 `/museek` pointing to 18080 and
   preserve every other route. Do not enable Funnel for port 10002.
5. Verify the public upstream and public Funnel return 404 for join even with
   spoofed identity headers. Verify private access with an allowed Tailscale user,
   denial for an unlisted user and Funnel-marked requests, normal library grants,
   and device-session revocation. Do not log tokens during smoke tests.
6. Build/upload native TestFlight using the existing release workflow only after
   review. This feature does not change signing or release settings.

## Tests

```sh
cd server && go test -race ./...
```

On macOS, use XcodeGen in `app/` then `xcodebuild test -project
Museek.xcodeproj -scheme Museek -destination 'platform=iOS Simulator,name=iPhone
17 Pro'`. The scheme includes unit and UI tests. UI tests exercise found, denied
join and manual invitation fallback and retain a screenshot in the xcresult.
`MUSEEK_UI_TEST_SCENARIO` only changes behavior in DEBUG builds; it is not compiled
into release/TestFlight builds. Live Tailscale routing still requires the operator
smoke tests above; deterministic simulator tests do not prove live identity ingress.
