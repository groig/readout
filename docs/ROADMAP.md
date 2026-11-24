# Roadmap

Ideas that are not built yet. Each has the decision it needs first, if any.

## Product

- **AI summaries and "ask the document"**: a summary on the document page and questions answered
  from the pages' text (already extracted and indexed). *Decision:* where the model runs. A hosted
  API sends document text to a third party, which conflicts with "nothing leaves our server"; a
  self-hosted model needs a GPU or accepts slow answers. Make it opt-in per workspace either way.
- **Email digests**: a daily or weekly summary of activity on the documents you follow, as an
  alternative to in-app notifications (respects `Readout.Mailer.enabled?/0`, one per person in their
  language).
- **Notification channels**: Rocket.Chat, Teams or webhooks, as separate deliverers next to the
  in-app one (HTTP through `Req` with config-driven options so tests can stub them).
- **Viewer download-blocking polish**: disable right-click/drag on page images, a print stylesheet
  that hides pages, and a blur when the tab loses focus. Deterrents only; the burned-in watermark
  is what traces leaks.
- **Watermark for spreadsheets**: sheets render as HTML tables and keep the CSS overlay; a burned-in
  version would mean rendering tables as images, which loses the table and chart views.
- **Room analytics export**: the same CSVs as documents, across a room's documents.

## Identity and access

- **SSO (Microsoft Entra ID / OIDC)** for team sign-in, with invitations still deciding who joins.
- **Custom domains** for share links (e.g. `docs.example.com/v/...`), needing per-domain TLS in
  Caddy and a link base URL setting.

## Operations

- **S3-compatible storage adapter** behind `Readout.Storage` (signed URLs or proxied reads; the
  watermark cache stays local).
- **Backup and restore script**: `pg_dump` plus the storage directory, with a documented restore
  and a check that the two match.
- **Retention and privacy cleanup**: delete or anonymise visits older than a configurable age
  (emails, IPs, devices), and remove page views with them; show the policy to viewers on the gate.
- **Monthly GeoIP refresh**: an Oban cron job that downloads the new DB-IP Lite release, verifies
  it opens, and swaps it in (`Readout.GeoIP` caches the database, so it needs a reload).
- **Rooms in the command palette** and room search.
