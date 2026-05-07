# Phantty Remote Console

Cloudflare Worker scaffold for Phantty remote access.

This is the Cloudflare relay for Phantty remote access. It provides:

- Single-user login API.
- Signed login cookie.
- Static `xterm.js` browser console.
- Durable Object WebSocket relay.
- Read-only default behavior with local approval before remote input.

The browser mirrors Phantty tabs and split panels from layout snapshots, then
routes approved input back to the selected surface.

## Setup

Install dependencies:

```powershell
npm install
```

Create a local Wrangler config from the example:

```powershell
Copy-Item .\wrangler.toml.example .\wrangler.toml
```

For deployment to your custom domain, uncomment and set this route in the local
`wrangler.toml`:

```toml
[[routes]]
pattern = "remote.example.com"
custom_domain = true
```

Set Worker secrets:

```powershell
wrangler secret put ADMIN_USERNAME
wrangler secret put ADMIN_PASSWORD_HASH
wrangler secret put SESSION_SIGNING_SECRET
```

`ADMIN_PASSWORD_HASH` currently uses:

```text
sha256:<lowercase-hex-sha256-of-password>
```

On Linux, generate it without adding a newline or losing backslashes:

```bash
IFS= read -r -s -p "Admin password: " PW; echo
printf '%s' "$PW" | sha256sum | awk '{print "sha256:" $1}'
unset PW
```

Build and deploy:

```powershell
npm run build
wrangler deploy
```

## Routes

- `GET /` serves the browser app.
- `POST /api/login` signs in the single configured user.
- `POST /api/logout` clears the login cookie.
- `GET /api/me` checks login state.
- `GET /ws/browser?session=<key>` connects the browser after login.
- `GET /ws/phantty?session=<key>` connects the shared Phantty RemoteClient.

## Relay Messages

The Phantty client sends PTY bytes as:

```json
{ "type": "output-bytes", "surfaceId": "0000000000000001", "encoding": "hex", "data": "..." }
```

Phantty also sends layout snapshots so the browser can render tabs and split
panels separately:

```json
{ "type": "layout", "activeTab": 0, "tabs": [] }
```

Browser input is routed back to the selected surface:

```json
{ "type": "input-bytes", "surfaceId": "0000000000000001", "encoding": "hex", "data": "0d" }
```

Input stays read-only until the browser requests control and Phantty grants it:

```json
{ "type": "request-control" }
{ "type": "control-requested" }
{ "type": "control-granted" }
{ "type": "control-revoked" }
```

The browser also accepts the older mock format:

```json
{ "type": "output", "data": "hello from mock Phantty\r\n" }
```

## Security Notes

- Do not commit Worker secrets.
- Do not load third-party browser scripts into the console page.
- Replace the Phase 1 password hash format with a slow KDF before production.
- Add Phantty device challenge/response before trusting `/ws/phantty`.
