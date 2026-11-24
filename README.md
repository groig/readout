# Readout

Readout is a self-hosted document sharing service with reading analytics. Upload a
report, proposal or deck (PDF, Word, PowerPoint), share it through links, and see who opened it,
which pages they read and for how long, live.

It is free software, runs as one Docker Compose stack behind Caddy, and keeps every file and every
analytics event on our own server. Nothing is sent to third parties.

> Status: milestones 1–4 are done: foundation; documents; share links and the public viewer with
> email; reading analytics (time per page measured on the server, live "reading now", activity
> feed). Notifications and deployment follow. See `docs/ARCHITECTURE.md`.

## Run it locally

Requirements: Elixir 1.17+ / OTP 27+, PostgreSQL, LibreOffice (`soffice`), poppler
(`pdfinfo`, `pdftoppm`, `pdftotext`) and `cwebp` (Arch: `libwebp-utils`, Debian: `webp`).
Tests that need these tools are tagged `:tools` and skipped with a note if one is missing.

```sh
mix setup                      # deps, database, assets
mix run priv/repo/seeds.exs    # optional: a demo team
mix phx.server                 # http://localhost:4000
```

On a fresh database, `/` sends you to the first-run setup screen, where you create the owner
account. With seeds, sign in as `owner@readout.test` (also `admin@`, `member@`, `observer@`) with
the password `readout-dev-password`.

Optional: IP locations in analytics need a GeoIP database. For development, download DB-IP Lite
City (free, CC BY 4.0) into `tmp/geoip/city.mmdb`:

```sh
mkdir -p tmp/geoip && curl -L https://download.db-ip.com/free/dbip-city-lite-$(date +%Y-%m).mmdb.gz | gunzip > tmp/geoip/city.mmdb
mix run priv/repo/demo_analytics.exs   # optional: 30 days of demo visits
```

Useful dev pages (all under `/dev`, which production keeps tailnet-only):

- `/dev/design` is the style guide: every token and component, in both themes.
- `/dev/mailbox` shows the emails the app sent.
- `/dev/dashboard` is Phoenix LiveDashboard.

## Develop

- Read `AGENTS.md` first: Phoenix, LiveView and HEEx rules, plus this project's own rules.
- `mix precommit` compiles with warnings as errors, formats and runs the tests. Run it before
  every commit.
- Uploaded files go to `tmp/storage` in development (`STORAGE_PATH` in production).
- UI strings go through Gettext. After changing them, run `mix gettext.extract --merge`, then
  translate the new entries in `priv/gettext/es/LC_MESSAGES/*.po`.

## Deploy

The release Dockerfile, `compose.example.yml`, `/healthz` and the deployment guide arrive in
milestone 5. Configuration comes only from environment variables:

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | `ecto://user:pass@host/db` |
| `SECRET_KEY_BASE` | yes | `mix phx.gen.secret` |
| `PHX_HOST` | yes | public host, e.g. `share.example.com` |
| `STORAGE_PATH` | yes | where files live (a volume) |
| `SMTP_HOST`, `SMTP_PORT` (587), `SMTP_USERNAME`, `SMTP_PASSWORD` | no | email; without it invitations are copy-only and links can't verify emails |
| `MAIL_FROM`, `MAIL_FROM_NAME` (`Readout`) | no | sender |
| `TRUSTED_PROXIES` | no | CIDRs allowed to set `X-Forwarded-For` (default: loopback + private ranges) |
| `MAX_UPLOAD_MB` (100), `TOOL_TIMEOUT` (180 s) | no | limits |
| `GEOIP_DB_PATH` | no | MaxMind DB file (e.g. DB-IP Lite City) for viewer locations |
| `ROCKETCHAT_WEBHOOK_URL` | no | notifications (milestone 5) |
