# Readout

Readout is a self-hosted document sharing service with reading analytics. Upload a
report, proposal or deck (PDF, Word, PowerPoint), share it through links, and see who opened it,
which pages they read and for how long, live.

It is free software, runs as one Docker Compose stack behind Caddy, and keeps every file and every
analytics event on our own server. Nothing is sent to third parties.

What it does:

- **Documents**: upload PDF, Word (DOCX/ODT) or PowerPoint (PPTX/ODP) by dropping them anywhere;
  Office files are converted to PDF with LibreOffice; pages are rendered and their text indexed.
  Spreadsheets (XLSX, ODS, CSV) are shown as tables with a chart view.
  New versions keep every link working.
- **Links**: one link per person or group, with optional expiry, password, email gate (allow and
  block lists), verified email (6-digit code), download and a watermark burned into every page
  and download (traceable to the visit).
- **Rooms**: several documents behind one link (a deal, a board pack), in your order, with the
  same link settings; each document read counts in its own analytics and in the room's roll-up.
- **Analytics**: who opened what, which pages and for how long (measured on the server), live
  "reading now" with the reader's current page, per-link and per-viewer breakdowns, and an
  activity feed. In-app notifications when someone opens or finishes a document you follow.
- **Team**: owners, admins, members and observers; invitations; audit log; English and Spanish.

See `docs/ARCHITECTURE.md` for the design (data model, tracking, security).

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

Readout ships as one Docker image (the Elixir release plus LibreOffice, poppler, cwebp and fonts)
and runs as a Compose stack (app + Postgres) behind Caddy.

1. Copy `compose.example.yml`, `.env.example` (as `.env`) and `deploy/Caddyfile.example` into the
   infra repo and fill in the secrets (`mix phx.gen.secret` for `SECRET_KEY_BASE`).
2. Optional, for viewer locations: download DB-IP Lite City (free, CC BY 4.0) into `./geoip/` and
   refresh it monthly:

   ```sh
   mkdir -p geoip && curl -L https://download.db-ip.com/free/dbip-city-lite-$(date +%Y-%m).mmdb.gz | gunzip > geoip/city.mmdb
   ```

3. `docker compose -f compose.example.yml up -d --build`. Migrations run on every boot.
4. Open `https://$PHX_HOST/`: the first visit shows the setup screen for the owner account.

Operations:

- Health: `GET /healthz` (database and storage), also used by the image's `HEALTHCHECK`.
- Data: the `storage` volume (files) and the `db` volume (Postgres). Back up both.
- Internal tools under `/dev/*` (LiveDashboard, owners and admins only) are tailnet-only in Caddy.
- Logs go to stdout. `docker compose exec app bin/readout remote` opens a console.
- Document conversion runs without network access where the kernel allows unprivileged user
  namespaces; Docker's default seccomp profile usually doesn't, and Readout then logs a warning and
  relies on LibreOffice's own lockdown (no macros, a fresh profile, a timeout).

Configuration (environment variables only):

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | `ecto://user:pass@host/db` |
| `SECRET_KEY_BASE` | yes | `mix phx.gen.secret` |
| `PHX_HOST` | yes | public host, e.g. `share.example.com` |
| `STORAGE_PATH` | yes (image default `/data/storage`) | where files live |
| `SMTP_HOST`, `SMTP_PORT` (587), `SMTP_USERNAME`, `SMTP_PASSWORD` | no | email (Office 365: `smtp.office365.com`, STARTTLS); without it invitations are copy-only and links can't verify emails |
| `MAIL_FROM`, `MAIL_FROM_NAME` (`Readout`) | no | sender |
| `GEOIP_DB_PATH` | no | MaxMind DB file (e.g. DB-IP Lite City) for viewer locations |
| `TRUSTED_PROXIES` | no | CIDRs allowed to set `X-Forwarded-For` / `-Proto` (default: loopback + private ranges) |
| `MAX_UPLOAD_MB` (100), `TOOL_TIMEOUT` (180 s), `POOL_SIZE` (10) | no | limits |
