# Contractor CRM Starter

A complete, self-hosted CRM for one contractor or home-service business — quotes, invoices, sales pipeline, online booking, email follow-ups and a customer portal — built on a stack a solo developer can own end to end:

**static HTML/CSS/JS (no build step) · Netlify (hosting + serverless functions) · Supabase (Postgres, Auth, Storage) · Resend (email)**

Optional: **Stripe Connect** for card payments and **Google Calendar** sync.

This is a starting point for people who want to build their *own* CRM rather than rent one. Click **Use this template**, point it at your own Supabase and Netlify accounts, and it's yours — your code, your data, nothing phones home.

> **Ready to set it up?** Follow **[SETUP.md](SETUP.md)** — it walks through every step, start to finish, in about 30 minutes.
> **Building on it with Claude Code or another AI assistant?** **[CLAUDE.md](CLAUDE.md)** explains how the app is put together so the assistant makes changes the right way.

---

## What's included

**Sales**
- Deals pipeline with custom stages, lead sources and automatic stage moves
- Quotes with good / better / best options, line items, pricing attributes, bundles, and "attached document" quotes
- Customer-facing quote links with accept / decline / choose-an-option, deposits and e-signature-style acceptance
- Change orders with customer approval links

**Money**
- Invoices (from quotes or standalone), partial payments, payment history
- Online card payments through the business's own Stripe account (optional)
- Banking / ledger pages, chart of accounts, financial reports
- Vendors

**Scheduling & intake**
- Embeddable booking forms (`<script>` embed or hosted page)
- Public appointment scheduler with availability rules, confirmations, reminders, cancel/reschedule links
- Google Calendar two-way sync (optional)

**Communication**
- Email templates with a block editor and merge fields
- Automated stage-based email sequences
- Bulk email to customer segments
- Delivery tracking via Resend webhooks, automatic retry of failed sends

**Operations**
- Today view, punch lists, print-ready price worksheets
- Customer portal (magic-link login): quotes, invoices, payments, project files, photo uploads
- Team members with roles and per-action permissions, invite-by-email
- Per-business branding (logo, color), settings and numbering

## How it's organized

```
public/            the whole front end — plain HTML pages + shared JS/CSS
  admin/           staff pages (login, dashboard, quotes, invoices, settings…)
  portal/          customer portal pages
  js/utils.js      shared helpers: Supabase client, auth, fetch wrapper, UI bits
netlify/functions/ serverless endpoints (email sending, public links, Stripe, Google, cron jobs)
database/          SQL to create the schema, functions, security policies — run in order
scripts/           rename.js, bundle-sql.js, check-setup.js, inject-env.js
```

There is **no build step**: `scripts/inject-env.js` runs on Netlify and drops your public Supabase URL/key into `public/js/utils.js`. Everything else is served as written.

## Single business, by design

This starter runs **one business**. The first person to open `/admin/signup.html` creates the business and becomes its Admin; after that the page turns into a sign-in page and everyone else joins by invitation (Settings → Team Members). The database still carries an `org_id` on every table — all business data is scoped to that one business by row-level security — so the data model is secure and consistent, but there is no business switcher and no public sign-up.

## Make it yours

```bash
# 1. Give it your name (page titles, emails, sign-in pages)
node scripts/rename.js "Summit Field CRM"

# 2. Swap the logo
#    public/images/logo-placeholder.svg

# 3. Check your environment variables
node scripts/check-setup.js
```

Then edit anything. It's plain HTML and JavaScript — open a page in `public/admin/`, change it, push, Netlify deploys.

## Local development

```bash
npm install
npm install -g netlify-cli      # once
cp .env.example .env            # fill it in
netlify dev                     # http://localhost:8888
```

## License

Free to use and modify for your own business or for a business you build it for. Not for resale as a template or as a hosted multi-customer product. See [LICENSE](LICENSE).
