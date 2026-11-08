# Setup Guide

From zero to a working CRM in about 30 minutes. You'll need free accounts at **GitHub**, **Supabase**, **Netlify** and **Resend**. Stripe and Google are optional and come last.

Every step below is something you do once. When you're done, your CRM is running at your own URL, on your own accounts, and you can start changing the code.

---

## 1. Make your own copy of the code

1. On this repository's GitHub page, click the green **Use this template** button → **Create a new repository**.
2. Name it whatever you like (e.g. `my-crm`), set it to **Private**, and create it.

You now own an independent copy. Nothing you change affects anyone else, and nobody else can see it.

> If you'd rather work locally first: `git clone <your new repo URL>` and open the folder in your editor.

## 2. Create the database (Supabase)

1. Go to [supabase.com](https://supabase.com) → **New project**. Pick any name, a strong database password (save it), and the region closest to you.
2. Wait for the project to finish provisioning (about a minute).
3. In the left sidebar open **SQL Editor** → **New query**.
4. Open the file **`database/00-ALL-IN-ONE.sql`** from your repo, copy its *entire* contents, paste it into the editor, and click **Run**.
   - It takes 10–20 seconds. You should see "Success. No rows returned."
   - If it errors, the message names the line. Most often it's a partial paste — clear the editor and paste the whole file again on a fresh project.
5. Go to **Project Settings → API** and keep this tab open. You need three values:
   - **Project URL** → `SUPABASE_URL`
   - **anon public** key → `SUPABASE_ANON_KEY`
   - **service_role** key → `SUPABASE_SERVICE_ROLE_KEY` (secret — this one bypasses security rules; it only ever goes into Netlify, never into the browser or the repo)

That's the whole database. Tables, security policies, the `Uploads` storage bucket and the sign-up logic are all created by that one file.

## 3. Set up email (Resend)

The app sends quotes, invoices, invites, password resets and reminders by email through Resend.

1. Go to [resend.com](https://resend.com) → **Domains** → **Add domain**. Use a domain you control (e.g. `yourbusiness.com`).
2. Add the DNS records Resend shows you at your domain registrar, then click **Verify**. (DNS can take a few minutes to a few hours.)
3. **API Keys** → **Create API key** → copy it → `RESEND_API_KEY`.
4. Decide on a sender address on that domain, e.g. `notifications@yourbusiness.com` → `EMAIL_FROM`. It doesn't need to be a real mailbox. Replies from customers go to the business email you set later in Settings.

> No domain yet? Resend lets you send to *your own* email address from `onboarding@resend.dev` for testing. Use that as `EMAIL_FROM` for now and switch when your domain is verified.

## 4. Deploy the site (Netlify)

1. Go to [netlify.com](https://netlify.com) → **Add new site** → **Import an existing project** → **GitHub** → choose the repo you created in step 1.
2. Build settings are read from `netlify.toml`; leave them as they are. Click **Deploy**. The first deploy will "work" but the app can't talk to the database yet — that's next.
3. **Site configuration → Environment variables → Add a variable → Import from a .env file**, and paste:

   ```
   SUPABASE_URL=https://xxxx.supabase.co
   SUPABASE_ANON_KEY=eyJ...
   SUPABASE_SERVICE_ROLE_KEY=eyJ...
   RESEND_API_KEY=re_...
   EMAIL_FROM=notifications@yourbusiness.com
   SITE_URL=https://your-site-name.netlify.app
   ```

   `SITE_URL` is the address Netlify gave your site (shown at the top of the site overview). No trailing slash. If you add a custom domain later, update this.
4. **Deploys → Trigger deploy → Deploy site** so the new variables take effect.

## 5. Create your business (one time)

1. Open `https://your-site-name.netlify.app/admin/signup.html`.
2. Enter your business name, your name, email and a password. This creates the business and makes you its Admin.
3. You're taken to **Settings**. Fill in company details, upload a logo, pick a brand color.

That sign-up page now permanently redirects to sign-in. Everyone else joins through **Settings → Team Members → Invite**, which emails them a link to set their own password.

**Try it:** create a customer, build a quote, email it to yourself, open the link, accept it. Then open `/portal/login.html` and request a magic link to the customer's email.

## 6. (Optional) Give it your name

By default the app calls itself "YourCRM" in page titles and emails. From the repo folder:

```bash
node scripts/rename.js "Summit Field CRM"
git commit -am "Rename app" && git push
```

Replace `public/images/logo-placeholder.svg` with your logo while you're at it.

## 7. (Optional) Online card payments — Stripe Connect

This lets customers pay deposits and invoices by card. The way it works: *your* Stripe account is the "platform", and the business connects *its own* Stripe account through it; money goes straight to the business. No platform fee is taken. (If you are the business, you'll connect the same Stripe account to itself — that's fine.)

1. Create a Stripe account at [stripe.com](https://stripe.com) if you don't have one.
2. **Settings → Connect → Get started**, choose **Platform or marketplace**, and complete the profile. Standard accounts are used.
3. **Developers → API keys** → copy **Secret key** → `STRIPE_SECRET_KEY` and **Publishable key** → `STRIPE_PUBLISHABLE_KEY`. Use test keys first; swap for live keys when you're ready.
4. **Developers → Webhooks → Add endpoint**:
   - Endpoint URL: `https://your-site-name.netlify.app/.netlify/functions/stripe-webhook`
   - **Listen to: Events on Connected accounts** (important — not "your account")
   - Events: `checkout.session.completed`, `payment_intent.succeeded`, `payment_intent.payment_failed`
   - After saving, reveal the **Signing secret** (`whsec_…`) → `STRIPE_WEBHOOK_SECRET`
5. Add the three variables in Netlify and redeploy.
6. In the app: **Settings → Online Payments → Connect with Stripe** and finish Stripe's onboarding. "Pay by card" buttons appear on quotes and invoices once Stripe reports the account ready.

## 8. (Optional) Google Calendar sync

Appointments booked through the scheduler get pushed to a Google Calendar and kept in sync.

1. [console.cloud.google.com](https://console.cloud.google.com) → create a project (any name).
2. **APIs & Services → Library** → enable **Google Calendar API**.
3. **APIs & Services → OAuth consent screen** → External → fill in app name and your email → add the scope `https://www.googleapis.com/auth/calendar.events` → add yourself as a test user. (Keep it in *Testing* unless you need more than 100 users; test tokens expire after 7 days in Testing mode, so for daily use click **Publish app**.)
4. **Credentials → Create credentials → OAuth client ID → Web application**:
   - Authorized redirect URI: `https://your-site-name.netlify.app/.netlify/functions/gcal-callback`
   - Copy **Client ID** → `GOOGLE_CLIENT_ID`, **Client secret** → `GOOGLE_CLIENT_SECRET`
5. Add both in Netlify, redeploy, then **Settings → Google Calendar → Connect**.

## 9. (Optional) Email delivery tracking

To see delivered / bounced / opened status on sent emails:

1. Resend → **Webhooks → Add webhook** → URL `https://your-site-name.netlify.app/.netlify/functions/resend-webhook`, select all email events.
2. Copy the signing secret → `RESEND_WEBHOOK_SECRET` in Netlify → redeploy.

---

## Running it on your computer

```bash
npm install
npm install -g netlify-cli
cp .env.example .env        # paste the same values you gave Netlify
node scripts/check-setup.js # confirms nothing is missing
netlify dev                 # opens http://localhost:8888 with functions running
```

Stripe and Google callbacks point at your live `SITE_URL`, so test those features on the deployed site.

## Scheduled jobs

`netlify.toml` schedules four functions (appointment reminders hourly, sequence emails and failed-email retries every 15 minutes, quote expiry daily). Netlify runs them automatically once deployed — nothing to configure.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Sign-up page says "This app is already set up" | A business already exists. Sign in instead, or ask the admin for an invite. To start over, delete the row in Supabase → Table Editor → `organizations` (this cascades to all its data). |
| Pages load but say "Failed to load" / blank data | `SUPABASE_URL` or `SUPABASE_ANON_KEY` missing or wrong in Netlify, or you didn't redeploy after adding them. |
| Emails never arrive | `RESEND_API_KEY` wrong, domain not verified, or `EMAIL_FROM` isn't on the verified domain. Check Resend → Logs. |
| Password reset / invite links go to the wrong address | `SITE_URL` is wrong or has a trailing slash. |
| "Online payments aren't switched on" in Settings | One or more `STRIPE_*` variables missing. All three are needed. |
| Stripe payment succeeded but invoice isn't marked paid | Webhook is listening on *your account* instead of *connected accounts*, or the signing secret doesn't match. Check Stripe → Webhooks → recent deliveries. |
| Google: "redirect_uri_mismatch" | The redirect URI in Google Cloud must match exactly: `https://<SITE_URL host>/.netlify/functions/gcal-callback`. |

## Adding a database change later

Create `database/08-your-change.sql`, run it in the Supabase SQL editor, then `node scripts/bundle-sql.js` so the all-in-one file stays current for anyone setting up fresh.
