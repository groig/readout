# Readout architecture

This is a living document, updated at the end of each milestone.

## Stack

Phoenix 1.8, LiveView 1.2, Ecto and Postgres, Tailwind v4 with our own design system (no
daisyUI). Oban (milestone 2) runs background jobs, poppler and LibreOffice convert documents, and
Swoosh with SMTP sends email. There are no JavaScript dependencies beyond what Phoenix ships.

## Contexts

| Module | Responsibility |
|---|---|
| `Readout.Accounts` | First-run setup, sign-in (password and magic link), invitations, members, roles, deactivation, ownership transfer, profile. |
| `Readout.Policy` | **All** authorization: `can?(scope, action, resource)` and `authorize/3`. |
| `Readout.Audit` | Append-only audit log, with live updates over PubSub. |
| `Readout.Workspace` | The single-row workspace settings (name, notification language). |
| `Readout.TimeZones` | IANA zones (the `tz` package) for pickers and conversion. |
| `Readout.Documents` | Documents, versions, pages, document members; upload, processing hooks, search. |
| `Readout.Storage` | Behaviour for file storage; `Storage.Local` writes under `STORAGE_PATH`. |

The web layer (`ReadoutWeb`) contains LiveViews, the shell, the components and locale resolution.

## Data model (milestone 1)

- **users**: email (citext), hashed password, name, `role` (`owner|admin|member|observer`, with a
  check constraint), avatar colour, locale (`auto|en|es`), time zone (null means "use the
  browser's"), theme, the notifications flag, `deactivated_at`, `last_active_at`. Users are never
  deleted.
- **users_tokens**: sessions, magic-link and email-change tokens (from `phx.gen.auth`).
- **invitations**: email, role, the **SHA-256 of the token** (the raw token exists only in the
  link), `expires_at` (7 days), `accepted_at`/`revoked_at`, inviter. A partial unique index allows
  only one open invitation per email.
- **audit_events**: action (`invitation.created`, `user.role_changed`, and so on), the actor id
  plus a **copy of the actor's name** and the subject's label (so entries stay readable), a
  metadata map, and a microsecond timestamp. It is append-only.
- **workspace_settings**: a single row (`id = 1`, enforced by a check constraint).

## Data model (milestone 2)

- **documents**: title, `visibility` (`workspace|restricted`), `owner_id`, `current_version_id`
  (the newest *ready* version — links keep working while a new version processes or if it fails),
  `deleted_at` (soft delete: files are removed, history stays).
- **document_versions**: `number` (1, 2, …), `status` (`pending|processing|ready|failed`), `error`
  (a stable code, translated in the UI), `format` (`pdf|docx|pptx|odt|odp`), original file name,
  size, SHA-256, `original_key`, `pdf_key` (the original itself for PDFs), page count, PDF metadata.
- **document_pages**: per version and page: size in PDF points (so viewers reserve space before
  images load), extracted text, and a generated `tsvector` (`simple` config, works for English and
  Spanish) with a GIN index for full-text search.
- **document_members**: people added to a document as `editor` or `viewer`.
- **oban_jobs**: Oban's queue table.

Storage keys: `documents/<id>/v<n>/original.<ext>`, `…/document.pdf`, `…/pages/<n>-<width>.webp`.

## Document processing

Upload (LiveView live upload, auto-upload, any page via the shell's drop overlay) →
`Documents.create_document/2` detects the format **by magic bytes** (`FileType`: `%PDF-`; ZIP with
`word/document.xml` / `ppt/presentation.xml`; ODF `mimetype`), enforces the size limit, stores
the original and inserts an Oban job **in the same transaction**.

`ProcessVersion` (queue `documents`, concurrency 2, 3 attempts) in a throwaway temp dir:

1. `Converter.to_pdf/3`: PDFs pass through; Office files go to `Converters.LibreOffice`
   (`soffice --headless --convert-to pdf` with a fresh profile per job, macros disabled, untrusted
   links blocked). New formats (spreadsheets) are new converter modules.
2. `pdfinfo`: page count, per-page sizes, metadata.
3. `pdftoppm` → PNG → `cwebp`: every page at 480 px (thumbnails) and 1600 px (viewing).
4. `pdftotext -layout`: per-page text (split on form feeds), NUL bytes stripped.
5. Pages are written, the version is marked ready, and becomes current if newer.

Every tool runs through `Documents.Tools.run/3`: coreutils `timeout` (default 180 s, then
SIGKILL) and, when the kernel allows unprivileged user namespaces, `unshare --net` so converters
have **no network**. Permanent errors (bad file, password-protected PDF) fail immediately; others
retry. Status changes are broadcast; the UI updates live.

## Links and the public viewer (milestone 3)

- **links**: `slug` (128 random bits, URL-safe), name, enabled, `expires_at`, bcrypt
  `password_hash`, `require_email`, `require_verification` (implies the email gate; needs SMTP),
  `allow_list` / `deny_list` (emails or domains; the deny list wins), `allow_download`,
  `allow_original_download`, `watermark`. Links always show the document's current version.
- **link_verifications**: 6-digit codes from a CSPRNG, stored as `HMAC(link_id, code)`; valid
  10 minutes; 5 attempts; one use. Sends are limited (3 per email and link per 15 minutes, 10 per
  client).
- **visits**: link, document, version, email, `email_verified`, client IP, user agent,
  `started_at` / `last_seen_at` / `ended_at`. A visit starts when a connected reader is through
  the gate, and ends when the LiveView terminates. Page timing is added in milestone 4.

**Gate flow** (`ViewerLive`, `/v/:slug`): unavailable (missing, disabled, expired, not ready) →
gate (password and/or email, rate-limited per link and client IP) → code (if verification) →
grant. The LiveView can't write cookies, so it hands a 2-minute signed grant token to
`ViewerAccessController` (via `phx-trigger-action`), which stores the grant in the session
(keyed by link and stamped with a time: changing the link's settings invalidates older grants)
and, for verified emails, sets a signed `rv_<slug>` cookie for 30 days (path-scoped to the link).
Returning devices skip the code.

**Page images** come from `/v/:slug/p/:token/:n/:width`, where the token is a `Phoenix.Token`
bound to the visit (2 hours). Every request re-checks the link, so disabling or expiring it cuts
access immediately. Downloads use the same token, require `allow_download`, and are audited with
the viewer's email.

**Watermark** (burned in): for links with `watermark`, `Documents.Watermark` tiles the reader's
email, the visit's start time and a short visit id diagonally into every page image and thumbnail
(ImageMagick, rendered on first request and cached per visit under `cache_dir`, pruned daily by an
Oban cron job). PDF downloads of such links are rebuilt from the watermarked pages as JPEGs by
`Documents.PdfWriter` (a minimal PDF writer, no dependency), and original files are never offered.
Spreadsheets, rendered as HTML tables, keep a CSS overlay. It survives screenshots and leaked files
and traces them to one visit; it can't stop someone retyping the content.

## Tracking and analytics (milestone 4)

**What the client may say**: which page is in view (`IntersectionObserver`, the most visible
page), whether the tab is visible (`visibilitychange`), and "still here" pings on interaction
(at most every 15 s). Events go over the viewer's LiveView socket; there is no extra endpoint.

**Unique viewers** are counted by email when there is one, else by device: a random id in a
first-party, HTTP-only cookie per link (`rd_<slug>`, set by the viewer plug), else by IP (when
cookies are blocked). People behind one office IP are told apart; one person on two devices
counts twice.

**What the server measures** (`Readout.Analytics.Tracker`, a pure state machine owned by the
viewer's LiveView): time accrues to the current page by the server's monotonic clock only while
the tab is visible, and only up to 2 minutes after the last sign of activity (idle readers stop
counting). After 30 minutes without activity the visit ends; a returning reader starts a new one.
Every 10 s (and when the LiveView terminates) the pending time is flushed with
`Analytics.record/4`: an upsert per page into **page_views** (`visit_id, page, duration_ms,
views`) and the visit's totals (`duration_ms`, `pages_viewed`, `last_page`, `last_seen_at`).

**Location**: `Readout.GeoIP` reads a MaxMind DB file (DB-IP Lite City by default, CC BY 4.0,
`GEOIP_DB_PATH`) in memory with a small built-in reader; country and city names are stored per
locale on the visit. Without the file, analytics show the IP.

**Live**: `ReadoutWeb.Presence` tracks each reading LiveView (key: visit id; meta: link, email,
location, current page) on `reading:<doc>` and `reading`. Visit start/update/end are broadcast on
`analytics` and `analytics:<doc>` (ids only). Document dashboards and the workspace feed re-read
through the scope and refresh stats at most every 2 s.

**Queries** (`Readout.Analytics`): overview (visits, unique viewers = distinct email-or-IP,
average time, completion = visits that reached the last page, deltas vs the previous period,
daily series in the person's time zone), time per page (average per visit and reach), per link,
viewers (grouped by email, or anonymous by IP), recent visits, a visit's page-by-page timeline,
and the workspace overview. All require `:view_document`; the workspace views only include
documents the person can see.

## Spreadsheets (CSV, XLSX, ODS)

A version's `kind` is `:pages` (documents) or `:sheets` (`xlsx`, `ods`, `csv`). For sheets,
`ProcessVersion` skips PDF and images: XLSX/ODS are exported to one CSV per sheet with LibreOffice
Calc (formula results, workbook order from its output); CSV is read directly
(`Documents.Sheets`: an RFC 4180 parser, delimiter sniffed from `, ; tab`, Latin-1 fallback).
Each sheet is stored as JSON (`sheets/<n>.json`: header, rows, numeric columns detected from
values like `1.234,5`, `12%`, `(45)`), capped at 20,000 rows × 200 columns. Each sheet is a
"page": its text is indexed for search, and reading time is tracked per sheet (the server sets
the page when the reader switches tabs). `ReadoutWeb.SheetView` holds the viewer state (sheet,
row page, table or chart) for both the document page and the public viewer. CSV files are
recognised by name (`.csv`) plus a text check, since they have no signature.

## Link limits

`links.max_viewers` caps how many people may open a link (the "one-time link" switch is a limit of
one). People are counted like unique viewers: by device id, then email, then IP. `Links.admits?/2`
lets in anyone who already has a visit on the link (same device or same email), otherwise only
while the count is below the limit. The viewer checks it at mount, or after the gate for links
that ask for an email (so a known reader on a new device gets back in). Two strangers arriving at
the same instant can exceed the limit by one; it's a courtesy limit, not a lock.

`links.notify_first_only` makes `Notifications.DeliverJob` skip visits that aren't the viewer's
first through that link (`Links.first_visit?/1`).

## Data rooms

- **rooms** (name, description, `workspace|restricted` visibility, owner, soft delete) and
  **room_documents** (ordered). A **link** points to a document *or* a room (a check constraint
  enforces exactly one).
- Adding a document needs `:edit_room` **and** `:edit_document` on it, so a room never shares what
  its editor couldn't share directly. Deleted documents leave rooms; documents without a ready
  version are hidden from viewers.
- Viewer: a room link passes the same gate, then shows the room's index (`:room`); each document
  opens at `/v/:slug/d/:document_id`. **Each document read is its own visit** (switching documents
  ends the previous one), so per-document analytics, notifications and presence work unchanged;
  per-link breakdowns include room links. `Analytics.room_overview/3` rolls visits up per room.

## Email

`ReadoutWeb.Emails` builds every email (translated, HTML and text, values escaped).
`Mailer.deliver_later/1` queues a `DeliverJob` (queue `mailers`, 5 attempts) whose argument is the
built email **encrypted with `SECRET_KEY_BASE`**, so tokens and codes are never readable in
`oban_jobs`. Without `SMTP_HOST`, `Mailer.enabled?/0` is false: invitations are copy-only, the
sign-in link and password-reset options are hidden, and links can't enable verification.
Production SMTP: STARTTLS on 587 with certificate and hostname verification (Office 365).

## Notifications

In-app only (the Rocket.Chat webhook from milestone 5 was removed on request).
`Readout.Notifications` creates **notifications** rows per person (kind, document, visit, a
`data` snapshot, `read_at`) and broadcasts `{:notification, id}` on `notifications:<user_id>`;
the shell forwards it to the bell (`ReadoutWeb.NotificationsComponent`: unread count, sheet,
toast). Text is rendered at display time in the reader's own language
(`ReadoutWeb.NotificationLabels`).

- Visit opened / finished (pages seen, total time, top page): created by
  `Notifications.DeliverJob` (Oban) for every **follower** of the document.
- Version ready / failed: for the uploader.

Following (**document_subscriptions**; the bell on the document page): by default you follow the
documents you own, if your profile's notification switch is on. Only active people who can see
the document are notified.

## Deployment (milestone 5)

- `Dockerfile` (from `mix phx.gen.release --docker`): Debian trixie runner with poppler-utils,
  webp, `libreoffice-{writer,impress}-nogui`, fonts (Carlito/Caladea for Calibri/Cambria,
  Liberation, DejaVu, Noto), tini as init, a non-root `readout` user, `/data` volume, and a
  `HEALTHCHECK` on `/healthz`.
- `bin/server` runs migrations, then starts the release.
- `ReadoutWeb.Plugs.Health` answers `/healthz` before sessions and logging (database + storage).
- Behind Caddy: `ReadoutWeb.ClientIP` trusts `X-Forwarded-For` and `X-Forwarded-Proto` only from
  `TRUSTED_PROXIES`, so client IPs are real and cookies are `Secure` (session cookies are always
  `Secure` in production).
- `/dev/*` holds the internal tools (LiveDashboard in production, plus the mailbox and style
  guide in development); one Caddy rule keeps the prefix tailnet-only, and LiveDashboard also
  requires an owner or admin.

## Client IPs

`ReadoutWeb.ClientIP` (plug and LiveView) trusts `X-Forwarded-For` only from `TRUSTED_PROXIES`
(CIDRs; defaults to loopback and Docker's private ranges), reading it right to left. Rate limits
(`Readout.RateLimit`, ETS fixed windows, single node) and visits use this address.

## Live updates

The shell (`ReadoutWeb.Shell`) subscribes every signed-in page to the `documents` topic and
forwards events (`{:document_created | :document_updated | :document_deleted, id}`) to the upload
tray and to the page's optional `handle_document_event/3`. Messages carry only ids; pages re-read
through their own scope, so a broadcast never leaks a document someone can't see.

## Authorization

`Readout.Accounts.Scope` holds the signed-in user plus the resolved locale and time zone. Every
context function that acts for someone takes the scope first and calls `Readout.Policy`.
LiveViews call `Policy.can?/3` to hide controls, and the context rejects the action anyway, which
the tests check by sending events the UI never offers. Pages gated by role use
`on_mount {ReadoutWeb.UserAuth, {:can, action}}`.

Role rules: owners can do everything. Admins invite and assign roles up to admin, and manage
members and observers. Only owners change or deactivate admins and owners. Nobody acts on
themselves; an owner steps down by transferring ownership, so the workspace always keeps at least
one owner. Documents: `:view_document` (admins/owners always; anyone for workspace documents; for
restricted ones the owner and people added), `:edit_document` (rename, versions, links: admins,
owners, the document owner, editors), `:manage_document` (visibility, people, delete: admins,
owners, the document owner). Observers never change anything. List queries apply the same rule in
SQL (`Documents.visible_to/2`). `test/readout/policy_test.exs` is the role × action
matrix.

## Sessions and live revocation

Every LiveView socket is tied to its session token (`live_socket_id`). Deactivating a user deletes
their tokens and broadcasts `disconnect` on each token's topic, so open tabs drop immediately and
can't reconnect. Changing a role (or transferring ownership) broadcasts the same `disconnect`
without deleting tokens, so tabs reconnect and remount with the new role.

## Locale and time

Locale: the profile setting (unless "Automatic"), then `Accept-Language`, then English. It is
resolved in a plug (`ReadoutWeb.Locale`) and again in `on_mount`, and sets `<html lang>`. The time
zone comes from the browser (LiveView connect params, plus a `tz` cookie for plain requests),
unless the profile overrides it. Everything is stored in UTC. `ReadoutWeb.Format` formats
numbers, durations, dates and relative times for the locale.

## Front end

- **Tokens** are in `assets/css/app.css` (`@theme`), and dark values are redefined under
  `[data-theme=dark]`. An inline script with a nonce sets the theme and sidebar state before
  first paint.
- **Components**: `CoreComponents` (primitives and forms), `OverlayComponents` (native `<dialog>`
  dialogs and sheets, dropdowns, CSS tooltips, toasts) and `ChartComponents` (SVG sparkline, CSS
  bar charts, stat tiles). All of them are showcased at `/dev/design`.
- **JavaScript**: `app.js` holds only global glue (theme, sidebar, dialog open and close,
  clipboard and client toasts, time zone, and view transitions on navigation only). Feature hooks
  are colocated: `.Shortcuts` (keyboard sequences via `data-shortcut`), `.Palette` (⌘K), `.Toast`,
  and `.ToastRegion` (keeps toasts in the top layer above dialogs).

## Files and caching

Team members get page images and downloads from `DocumentFileController`, which checks
`:view_document` on every request. Page images are immutable per version:
`Cache-Control: private, max-age=31536000, immutable`. Downloads are audited. Nothing under
`STORAGE_PATH` is ever served statically. (The public viewer's signed, visit-bound URLs arrive in
milestone 3.)

## Security notes

- Everything is private except `/v/*` (what a valid link exposes), sign-in, setup, invitations and
  password reset. Files are never served statically.
- Headers: strict CSP with nonces, `frame-ancestors 'none'`, `X-Content-Type-Options`,
  `Referrer-Policy` (`no-referrer` on the viewer), `Permissions-Policy`, `X-Robots-Tag: noindex`
  on the viewer; HSTS from Caddy.
- Rate limits: gate attempts (10 per 10 min per link and client), code sends (3 per email and link
  per 15 min, 10 per client), code checks (20 per 10 min), sign-in and reset emails (5 per address
  per 15 min).
- Secrets at rest: passwords and link passwords (bcrypt), invitation tokens (SHA-256), session and
  email tokens (hashed, from phx.gen.auth), verification codes (HMAC), queued emails (encrypted
  with `SECRET_KEY_BASE`).

- A strict CSP with a per-request nonce: scripts come only from our origin, there is no
  `unsafe-eval`, and there are no inline event handlers. Inline styles are allowed because
  LiveView JS commands use them. `frame-ancestors 'none'`.
- Invitation tokens are stored hashed. Login doesn't reveal whether an email exists. The magic link
  is valid for 15 minutes and works once.
- Sensitive account changes (email, password) require a sign-in within the last 10 minutes.
