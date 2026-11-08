# CLAUDE.md — how this app is built

Read this before changing anything. It explains the architecture, the conventions, and the rules that keep the app secure. The same guidance applies whether you're Claude Code, Cursor, Copilot or a person.

## What this is

A single-business CRM for contractors: quotes, invoices, pipeline, booking, email automation, customer portal.
**Stack:** plain HTML/CSS/JS front end (no framework, no bundler) · Netlify Functions (Node, CommonJS) · Supabase (Postgres + Auth + Storage, accessed with `@supabase/supabase-js`) · Resend for email · optional Stripe Connect and Google Calendar.

## Layout

```
public/                  everything served to the browser
  index.html             landing page
  admin/*.html           staff app — one page per screen, each self-contained (HTML + <script> at bottom)
  portal/*.html          customer portal (magic-link auth, no Supabase session)
  schedule.html, book.html, schedule-manage.html   public booking pages
  js/utils.js            shared: Supabase client, auth guard, `app.*` helpers, header/nav, toasts, fetch wrapper
  js/email-blocks.js     email template block renderer (shared by admin UI and functions)
  css/styles.css         design system (CSS variables, components); auth.css for sign-in pages
netlify/functions/*.js   one file per endpoint; utils.js has shared helpers
netlify/functions-phase2 NOT deployed. Parked prototypes (QuickBooks, Google Photos, AI assist).
database/NN-*.sql        schema, functions/triggers, RLS, seeds — applied in numeric order; 00-ALL-IN-ONE.sql is generated
scripts/                 rename.js, bundle-sql.js, check-setup.js, inject-env.js (runs at Netlify build)
netlify.toml             build, redirects (/api/* → functions, /schedule/*), headers, cron schedules
```

Pages call functions as `/api/<function-name>` (redirected to `/.netlify/functions/<name>`).

## The data model in one paragraph

Every business table has an `org_id` column pointing at `organizations`. There is exactly **one** organization in this app (created by the first sign-up), but the column stays and **row-level security on every table is `org_id = current_org_id()`**. `current_org_id()` reads the signed-in user's `profiles.active_org_id`. A `BEFORE INSERT` trigger (`fill_org_id`) sets `org_id` automatically on every insert — from the parent row where there is one (a quote line inherits its quote's org) or from the current user — so **browser code never sends `org_id`**. Don't add it to inserts, and don't filter by it in the browser; RLS already does.

Membership: `app_users` links an auth user to the org with a role from `app_roles` (per-action permission booleans). `profiles` holds name + `active_org_id`. Numbering (quotes, invoices, jobs, change orders) comes from `next_org_counter()`.

Storage: one public bucket `Uploads`; files live under `<org_id>/...` and storage policies only allow writes inside the user's own org folder.

## Two kinds of server code — know which one you're writing

**Staff endpoints** (anything a logged-in team member triggers — send a quote, invite a user, preview the portal): start with
```js
const auth = await requireStaff(event, 'can_send_quotes'); // permission optional
if (auth.error) return auth.error;
auth.supabase   // Supabase client acting AS THE USER → RLS applies, use this by default
auth.admin      // service-role client → bypasses RLS; only for what RLS can't do, and ALWAYS filter by auth.orgId
auth.orgId, auth.user, auth.member
```
On admin pages `public/js/utils.js` wraps `window.fetch` so any call to `/api/*` automatically carries `Authorization: Bearer <supabase access token>`. Just call `fetch('/api/whatever')`.

**Public endpoints** (a customer opening a quote link, a booking form, Stripe/Resend webhooks, cron jobs): no user session. These use the service-role client (`getSupabase()`), so **they must derive the business from the record they're serving** (`quote.org_id`, `invoice.org_id`, the appointment type's `org_id`) and pass that `orgId` into every settings read (`getOrgSetting(supabase, orgId, key)`) and every write. Never trust an `org_id` that arrives in the request body.

Tokens for public links (`auth_tokens` table: magic links, quote/invoice access, booking manage links) are random, single-purpose and expire. Reuse the existing patterns in `portal-login.js` / `schedule-manage.js` rather than inventing a new one.

## Email

All email goes through Resend via helpers in `netlify/functions/utils.js` (`platformFrom`, `getSiteUrl`) and `sequence-utils.js`. The sender is always `EMAIL_FROM` with the business name as display name; `reply_to` is the business's own email from settings. Templates are stored in the `email_templates` table as blocks rendered by `public/js/email-blocks.js` (the same file runs server-side). Sends are recorded in `email_logs`; failed ones are retried by `retry-failed-emails` on a schedule.

## Front-end conventions

- Each admin page is standalone: markup at top, `<script>` at bottom, loads `/js/utils.js`, which on load verifies the Supabase session, loads the user/org context, builds the header and nav, and redirects to login if needed — pages don't guard themselves. Use `app.requirePermission('can_x')` on pages that need a specific permission. Copy an existing page (e.g. `vendors.html`) when adding a new screen; add it to the nav in `utils.js`.
- Use the `app.*` helpers and CSS classes that already exist (`.btn`, `.card`, `.form-input`, `.table`, `showToast`, `confirm`, modal helpers). Look at a similar page before writing new UI.
- The Supabase client in the browser uses the **anon key** + the user's session. Browser code may read/write tables directly (RLS protects it) for simple CRUD; anything that sends email, touches Stripe/Google, or must bypass RLS goes through a function.
- Cache-busting is manual: `styles.css?v=40`, `utils.js?v=40`. Bump the number when you change those files.
- No build step. Don't introduce a bundler, framework, or TypeScript unless the owner asks.

## Database changes

1. Add a new numbered file `database/08-description.sql` (never edit an already-applied file in a way that wouldn't re-run cleanly — prefer `ADD COLUMN IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, etc.).
2. Any new table needs: `org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE`, the `fill_org_id` trigger, `ENABLE ROW LEVEL SECURITY`, and the standard policy `USING (org_id = current_org_id()) WITH CHECK (org_id = current_org_id())`. Copy the pattern from `03-security-onboarding.sql`.
3. Run it in the Supabase SQL editor, then `node scripts/bundle-sql.js`.

## Environment variables

See `.env.example`. Required: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `RESEND_API_KEY`, `EMAIL_FROM`, `SITE_URL`. Optional feature groups: `STRIPE_*` (all three or none), `GOOGLE_CLIENT_*` (both or none), `RESEND_WEBHOOK_SECRET`, `BOOKING_TOKEN_SECRET`. Features hide themselves in Settings when their variables are missing. `scripts/inject-env.js` replaces `__SUPABASE_URL__`, `__SUPABASE_ANON_KEY__`, `__STRIPE_PUBLISHABLE_KEY__`, `__SITE_URL__` in `public/js/utils.js` at build time — only public values, never the service key.

## Single-business mode

`auth-signup.js` refuses to create a second organization; `setup-status.js` tells the sign-up and login pages whether setup has happened. `getOrgBySlug()` returns the one business when no slug is given, so `/schedule` works without `/schedule/<slug>` (slugged URLs still work). The header's business switcher only renders when a user belongs to more than one org, which can't happen here. If you ever need multiple businesses, the schema already supports it — remove the guard in `auth-signup.js` and re-add a public sign-up link — but that's a different product than this starter.

## Things that will break the app if you get them wrong

- Putting the **service-role key** anywhere the browser can see it.
- A public function that reads settings without scoping to the record's `org_id`.
- A new table without RLS (every table is reachable with the anon key).
- Changing `fill_org_id` or `current_org_id()` without understanding every caller.
- Trusting IDs from the request body in webhooks — resolve the business from Stripe's `event.account` / the stored record instead.

## Useful commands

```bash
netlify dev                      # local site + functions on :8888
node scripts/check-setup.js      # verify env vars
node scripts/rename.js "Name"    # rebrand
node scripts/bundle-sql.js       # regenerate database/00-ALL-IN-ONE.sql
```
