# Readout

Readout is a self-hosted document sharing service with reading analytics. Upload a
report, proposal or deck (PDF, Word, PowerPoint), share it through links, and see who opened it,
which pages they read and for how long, live.

It is free software, runs as one Docker Compose stack behind Caddy, and keeps every file and every
analytics event on our own server. Nothing is sent to third parties.

> Status: milestone 1 (foundation) is done: design system, app shell, accounts, roles,
> invitations, members, audit log, profile, English and Spanish. Documents, links, the public
> viewer, analytics and deployment follow. See `docs/ARCHITECTURE.md`.

## Run it locally

Requirements: Elixir 1.17+ / OTP 27+, PostgreSQL, and (from milestone 2) `poppler-utils` and
LibreOffice.

```sh
mix setup                      # deps, database, assets
mix run priv/repo/seeds.exs    # optional: a demo team
mix phx.server                 # http://localhost:4000
```

On a fresh database, `/` sends you to the first-run setup screen, where you create the owner
account. With seeds, sign in as `owner@readout.test` (also `admin@`, `member@`, `observer@`) with
the password `readout-dev-password`.

Useful dev pages (all under `/dev`, which production keeps tailnet-only):

- `/dev/design` is the style guide: every token and component, in both themes.
- `/dev/mailbox` shows the emails the app sent.
- `/dev/dashboard` is Phoenix LiveDashboard.

## Develop

- Read `AGENTS.md` first: Phoenix, LiveView and HEEx rules, plus this project's own rules.
- `mix precommit` compiles with warnings as errors, formats and runs the tests. Run it before
  every commit.
- UI strings go through Gettext. After changing them, run `mix gettext.extract --merge`, then
  translate the new entries in `priv/gettext/es/LC_MESSAGES/*.po`.

## Deploy

The release Dockerfile, `compose.example.yml`, `/healthz` and the deployment guide arrive in
milestone 5. Configuration will come only from environment variables: `DATABASE_URL`,
`SECRET_KEY_BASE`, `PHX_HOST`, `STORAGE_PATH`, the `SMTP_*`/`MAIL_FROM*` settings and, optionally,
`ROCKETCHAT_WEBHOOK_URL`.
