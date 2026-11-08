#!/usr/bin/env node
// Checks that the environment variables the app needs are present.
//   node scripts/check-setup.js            (reads .env if present)
// Run it locally before `netlify dev`, or in a Netlify build log.

const fs = require('fs');
const path = require('path');

// Load .env without a dependency
const envFile = path.join(__dirname, '..', '.env');
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
}

const REQUIRED = {
  SUPABASE_URL: 'Supabase → Project Settings → API → Project URL',
  SUPABASE_ANON_KEY: 'Supabase → Project Settings → API → anon public key',
  SUPABASE_SERVICE_ROLE_KEY: 'Supabase → Project Settings → API → service_role key (secret!)',
  RESEND_API_KEY: 'Resend → API Keys',
  EMAIL_FROM: 'A sender on a domain you verified in Resend, e.g. notifications@yourdomain.com',
  SITE_URL: 'Your Netlify site URL, e.g. https://my-crm.netlify.app (no trailing slash)'
};

const OPTIONAL = {
  STRIPE_SECRET_KEY: 'Online payments (Stripe Connect platform account)',
  STRIPE_PUBLISHABLE_KEY: 'Online payments',
  STRIPE_WEBHOOK_SECRET: 'Online payments (Connect webhook signing secret)',
  GOOGLE_CLIENT_ID: 'Google Calendar sync',
  GOOGLE_CLIENT_SECRET: 'Google Calendar sync',
  RESEND_WEBHOOK_SECRET: 'Email delivery/bounce tracking (Resend webhook)',
  BOOKING_TOKEN_SECRET: 'Optional; derived from the service key when unset'
};

let ok = true;
console.log('Required:');
for (const [k, where] of Object.entries(REQUIRED)) {
  const set = !!process.env[k];
  if (!set) ok = false;
  console.log(`  ${set ? '✓' : '✗'} ${k}${set ? '' : '   ← ' + where}`);
}
console.log('\nOptional (feature stays hidden in Settings until set):');
for (const [k, why] of Object.entries(OPTIONAL)) {
  console.log(`  ${process.env[k] ? '✓' : '·'} ${k}   ${why}`);
}

if (process.env.SITE_URL && /\/$/.test(process.env.SITE_URL)) {
  console.log('\n⚠ SITE_URL should not end with a slash.');
}
const stripeSet = ['STRIPE_SECRET_KEY', 'STRIPE_PUBLISHABLE_KEY', 'STRIPE_WEBHOOK_SECRET'].filter((k) => process.env[k]).length;
if (stripeSet > 0 && stripeSet < 3) console.log('\n⚠ Stripe is half-configured — set all three STRIPE_* variables or none.');
const gSet = ['GOOGLE_CLIENT_ID', 'GOOGLE_CLIENT_SECRET'].filter((k) => process.env[k]).length;
if (gSet === 1) console.log('\n⚠ Google is half-configured — set both GOOGLE_* variables or neither.');

console.log(ok ? '\nAll required variables are set.' : '\nMissing required variables — see SETUP.md.');
process.exit(ok ? 0 : 1);
