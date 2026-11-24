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

## Authorization

`Readout.Accounts.Scope` holds the signed-in user plus the resolved locale and time zone. Every
context function that acts for someone takes the scope first and calls `Readout.Policy`.
LiveViews call `Policy.can?/3` to hide controls, and the context rejects the action anyway, which
the tests check by sending events the UI never offers. Pages gated by role use
`on_mount {ReadoutWeb.UserAuth, {:can, action}}`.

Role rules: owners can do everything. Admins invite and assign roles up to admin, and manage
members and observers. Only owners change or deactivate admins and owners. Nobody acts on
themselves; an owner steps down by transferring ownership, so the workspace always keeps at least
one owner. Documents (milestone 2) will add `:workspace`/`:restricted` visibility and per-document
editors and viewers to the same module. `test/readout/policy_test.exs` is the role × action
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

## Security notes

- A strict CSP with a per-request nonce: scripts come only from our origin, there is no
  `unsafe-eval`, and there are no inline event handlers. Inline styles are allowed because
  LiveView JS commands use them. `frame-ancestors 'none'`.
- Invitation tokens are stored hashed. Login doesn't reveal whether an email exists. The magic link
  is valid for 15 minutes and works once.
- Sensitive account changes (email, password) require a sign-in within the last 10 minutes.
