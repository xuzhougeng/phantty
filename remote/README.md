# Phantty Remote Console

Cloudflare Worker scaffold for Phantty remote access.

This is a Phase 1 foundation. It provides:

- Single-user login API.
- Signed login cookie.
- Static `xterm.js` browser console.
- Durable Object WebSocket relay skeleton.
- Read-only default behavior.

It does not provide production-ready device authentication or local control
approval yet. Those are required before remote input should be enabled.

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
- `GET /ws/phantty?session=<key>` is a scaffold route for the future Phantty client.

## Security Notes

- Do not commit Worker secrets.
- Do not load third-party browser scripts into the console page.
- Do not enable input forwarding until Phantty implements local approval.
- Replace the Phase 1 password hash format with a slow KDF before production.
- Add Phantty device challenge/response before trusting `/ws/phantty`.
