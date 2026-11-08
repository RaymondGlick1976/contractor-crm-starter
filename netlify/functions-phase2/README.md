# Not deployed

Prototype functions that are **not** wired up (`netlify.toml` only deploys `netlify/functions/`):

- `qb-*.js` — QuickBooks Online sync (customers, estimates, invoices, payments). The `quickbooks_connection` table already exists.
- `gphoto-*.js` — Google Photos job albums.
- `ai-quote-assist.js` — AI-assisted quote drafting.

They were written against an earlier single-business version and need to be brought in line with the patterns in `CLAUDE.md` (derive the business from the record, signed OAuth `state`, settings scoped by `org_id`) before moving them into `netlify/functions/`. Treat them as a head start, not finished code.
