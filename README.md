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
  and download (traceable to the visit), one-time links and viewer limits, and notifications for
  a viewer's first visit only.
- **Rooms**: several documents behind one link (a deal, a board pack), in your order, with the
  same link settings; each document read counts in its own analytics and in the room's roll-up.
- **Analytics**: who opened what, which pages and for how long (measured on the server), live
  "reading now" with the reader's current page, per-link and per-viewer breakdowns, and an
  activity feed, and CSV exports of visits and time per page. In-app notifications when someone opens or finishes a document you follow.
- **Team**: owners, admins, members and observers; invitations; audit log; English and Spanish.

See `docs/ARCHITECTURE.md` for the design (data model, tracking, security) and `docs/ROADMAP.md`
for what is planned next.

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

GitHub Actions tests and builds pull requests. A successful push to `main` publishes
`ghcr.io/groig/readout` with `latest`, `main`, and `sha-<short-commit>` tags. Version
tags such as `v1.2.3` publish a matching `1.2.3` image. After the first publication,
the maintainer must set the GHCR package visibility to **Public** to allow anonymous pulls.

1. Copy `compose.example.yml`, `.env.example` (as `.env`), `deploy/Caddyfile.example` and
   `deploy/seccomp.json` into the infra repo and fill in the secrets (`mix phx.gen.secret` for
   `SECRET_KEY_BASE`, `openssl rand -hex 16` for `SETUP_TOKEN`). Set `TRUSTED_PROXIES` to Caddy's
   address on the proxy network.
2. Optional, for viewer locations: download DB-IP Lite City (free, CC BY 4.0) into `./geoip/` and
   refresh it monthly:

   ```sh
   mkdir -p geoip && curl -L https://download.db-ip.com/free/dbip-city-lite-$(date +%Y-%m).mmdb.gz | gunzip > geoip/city.mmdb
   ```

3. `docker compose -f compose.example.yml up -d --pull always`. Migrations run on every boot.
4. Open `https://$PHX_HOST/`: the first visit shows the setup screen for the owner account. It
   asks for `SETUP_TOKEN` (or, without one, only `ADMIN_NETWORKS` can reach it; with neither it
   stays locked). Remove `SETUP_TOKEN` once the owner exists.

To pin a deployment, replace `latest` in Compose with the digest you reviewed
(`ghcr.io/groig/readout@sha256:…`) or at least the published commit tag. To build
from a source checkout, run `docker build -t readout:local .`, set the Compose app image
to `readout:local`, and start it with `docker compose -f compose.example.yml up -d`.

Operations:

- Health: `GET /healthz` (database and storage) for the image's `HEALTHCHECK`. It answers only
  the container itself (or `HEALTH_NETWORKS`); Caddy answers 404 for it.
- Data: the `storage` volume (files) and the `db` volume (Postgres). Back up both.
- Internal tools under `/dev/*` (LiveDashboard, owners and admins only) are tailnet-only in Caddy.
- Logs go to stdout. Request lines show route templates (`GET /v/:slug 200 in 8ms`), never paths,
  which carry share links and tokens. `docker compose exec app bin/readout remote` opens a console.
- Document conversion is contained: no network, its own user, PID and mount namespaces (stored files
  hidden, the app's environment unreadable), a minimal environment, and memory, CPU and file-size limits. It needs unprivileged user
  namespaces: Compose uses `deploy/seccomp.json` (Docker's default plus `unshare` and `mount`) and,
  on AppArmor hosts, `apparmor=unconfined`. Without them, conversions fail rather than run
  uncontained (`TOOL_ISOLATION=preferred` overrides that, at your own risk). Check with
  `docker compose exec app bin/readout eval 'IO.inspect Readout.Documents.Tools.network_isolation?()'`.

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
| `TRUSTED_PROXIES` | yes in Compose | CIDRs allowed to set `X-Forwarded-For` / `-Proto`: Caddy only (app default: loopback + private ranges) |
| `SETUP_TOKEN` | for first-run setup | code the setup screen asks for (16+ characters) |
| `ADMIN_NETWORKS` | no | CIDRs allowed to reach setup, members, audit and workspace settings |
| `HEALTH_NETWORKS` | no | CIDRs besides the container itself allowed to call `/healthz` |
| `TOOL_ISOLATION` (`required`) | no | `preferred` lets document tools run without namespaces |
| `MAX_UPLOAD_MB` (100), `TOOL_TIMEOUT` (180 s), `TOOL_MEMORY_MB` (2048), `TOOL_FILE_MB` (2048), `POOL_SIZE` (10) | no | limits |

## License

Readout is licensed under the GNU Affero General Public License, version 3 only
(`AGPL-3.0-only`). See [LICENSE](LICENSE).

Set `ADMIN_NETWORKS` to comma-separated client CIDRs when setup, workspace administration
(members, audit and workspace settings) and internal tools require a private network.
Apply the same restrictions at the reverse proxy. HTTP and connected LiveViews use
the client address resolved through `TRUSTED_PROXIES`.
