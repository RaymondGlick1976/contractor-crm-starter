// =============================================
// SHARED UTILITIES FOR NETLIFY FUNCTIONS
// =============================================

const { createClient } = require('@supabase/supabase-js');

// Initialize Supabase with service role for admin access
function getSupabase() {
  return createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY
  );
}

// Supabase client that acts AS the signed-in staff member (RLS applies → their business only)
function getUserClient(accessToken) {
  return createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false }
  });
}

function getBearerToken(event) {
  const h = (event.headers && (event.headers.authorization || event.headers.Authorization)) || '';
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

// Verify the caller is signed-in staff of a business.
// Returns { db, admin, orgId, member, user } or { response } (an error response to return).
// db  = client scoped to the caller (use for everything that touches business data)
// admin = service-role client (only for things RLS can't do, always filter by orgId)
async function requireStaff(event, permission) {
  const token = getBearerToken(event);
  if (!token) return { response: error('Please sign in again.', 401) };
  const admin = getSupabase();
  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  if (userErr || !userData?.user) return { response: error('Your session expired. Please sign in again.', 401) };
  const db = getUserClient(token);
  const { data: ctx, error: ctxErr } = await db.rpc('get_my_context');
  if (ctxErr || !ctx?.org?.id || !ctx?.member) return { response: error('This login is not linked to a business.', 403) };
  if (permission && !(ctx.member.role && ctx.member.role[permission])) {
    return { response: error('You do not have permission to do that.', 403) };
  }
  return { db, admin, orgId: ctx.org.id, org: ctx.org, member: ctx.member, user: userData.user };
}

// Read one settings value for a business (works with service-role or user clients)
async function getOrgSetting(supabase, orgId, key, fallback = {}) {
  const { data } = await supabase.from('settings').select('value')
    .eq('org_id', orgId).eq('key', key).maybeSingle();
  return (data && data.value) || fallback;
}

function getSiteUrl() {
  return (process.env.SITE_URL || 'https://your-site.netlify.app').replace(/\/+$/, '');
}

// All mail goes out from the platform's verified sender, branded with the business name,
// with replies going to the business's own address.
function platformFrom(businessName) {
  const addr = process.env.EMAIL_FROM || 'no-reply@example.com';
  const name = String(businessName || 'YourCRM').replace(/[<>"]/g, '').trim() || 'YourCRM';
  return `${name} <${addr}>`;
}

// ---------------------------------------------
// STRIPE CONNECT
// The platform (YourCRM) holds one Stripe secret key. Each business is a
// connected Standard account; charges are created directly on that account
// by passing { stripeAccount } on every call, so money lands with the business.
// ---------------------------------------------
function getPlatformStripe() {
  if (!process.env.STRIPE_SECRET_KEY) return null;
  const Stripe = require('stripe');
  return new Stripe(process.env.STRIPE_SECRET_KEY);
}

// Returns { stripe, account, ready } for a business. ready=false when the
// business hasn't connected Stripe or Stripe hasn't enabled charges yet.
async function getOrgStripe(supabase, orgId) {
  const stripe = getPlatformStripe();
  if (!stripe || !orgId) return { stripe: null, account: null, ready: false };
  const { data: org } = await supabase.from('organizations')
    .select('stripe_account_id, stripe_charges_enabled').eq('id', orgId).maybeSingle();
  const account = org?.stripe_account_id || null;
  return { stripe, account, ready: !!(account && org.stripe_charges_enabled) };
}

// ---------------------------------------------
// SIGNED TOKENS (booking redirects, OAuth state)
// ---------------------------------------------
function signingSecret() {
  if (process.env.BOOKING_TOKEN_SECRET) return process.env.BOOKING_TOKEN_SECRET;
  // Derived fallback so no extra setup is required; rotates if the service key rotates
  return require('crypto').createHash('sha256')
    .update('crm-signing:' + (process.env.SUPABASE_SERVICE_ROLE_KEY || '')).digest('hex');
}

function signToken(payload, ttlMs = 60 * 60 * 1000) {
  const crypto = require('crypto');
  const body = Buffer.from(JSON.stringify({ ...payload, exp: Date.now() + ttlMs })).toString('base64url');
  const sig = crypto.createHmac('sha256', signingSecret()).update(body).digest('base64url');
  return `${body}.${sig}`;
}

function verifyToken(token) {
  try {
    const crypto = require('crypto');
    const [body, sig] = String(token || '').split('.');
    if (!body || !sig) return null;
    const expected = crypto.createHmac('sha256', signingSecret()).update(body).digest('base64url');
    const a = Buffer.from(sig), b = Buffer.from(expected);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
    const payload = JSON.parse(Buffer.from(body, 'base64url').toString());
    if (!payload.exp || payload.exp < Date.now()) return null;
    return payload;
  } catch {
    return null;
  }
}

// Single-business app: with no slug, return the one business. Slugged URLs
// (/schedule/<slug>) keep working too.
async function getOrgBySlug(supabase, slug) {
  let q = supabase.from('organizations').select('id, name, slug, timezone');
  q = slug ? q.eq('slug', String(slug).toLowerCase()) : q.order('created_at', { ascending: true }).limit(1);
  const { data } = await q.maybeSingle();
  return data || null;
}

// Standard response helpers
function success(data, statusCode = 200) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    },
    body: JSON.stringify(data),
  };
}

function error(message, statusCode = 400) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    },
    body: JSON.stringify({ error: message }),
  };
}

// CORS preflight handler
function handleCors(event) {
  if (event.httpMethod === 'OPTIONS') {
    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      },
      body: '',
    };
  }
  return null;
}

// Parse request body
function parseBody(event) {
  try {
    return event.body ? JSON.parse(event.body) : {};
  } catch {
    return {};
  }
}

// Get session from cookie
function getSessionToken(event) {
  const cookies = event.headers.cookie || '';
  const match = cookies.match(/portal_session=([^;]+)/);
  return match ? match[1] : null;
}

// Validate portal session and return customer
async function validateSession(event) {
  const token = getSessionToken(event);
  if (!token) {
    return null;
  }
  
  const supabase = getSupabase();
  
  const { data: authToken, error: tokenError } = await supabase
    .from('auth_tokens')
    .select('*, customer:customers(*)')
    .eq('token', token)
    .eq('token_type', 'session')
    .gt('expires_at', new Date().toISOString())
    .single();
  
  if (tokenError || !authToken) {
    return null;
  }
  
  return authToken.customer;
}

// Set session cookie
function setSessionCookie(token, maxAge = 30 * 24 * 60 * 60) {
  const secure = process.env.NODE_ENV === 'production' ? '; Secure' : '';
  return `portal_session=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${secure}`;
}

// Clear session cookie
function clearSessionCookie() {
  return 'portal_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0';
}

// Generate random token
function generateToken() {
  return require('crypto').randomUUID();
}

// Advance a deal's pipeline stage forward (never backward).
// Finds the job by quoteId first, falls back to customerId.
// Only updates if the target stage's sort_order > current stage's sort_order.
async function advanceDealStage(supabase, { quoteId, customerId, targetStageId }) {
  try {
    // Find the job
    let job = null;
    if (quoteId) {
      const { data } = await supabase
        .from('jobs')
        .select('id, stage, org_id')
        .eq('quote_id', quoteId)
        .limit(1)
        .single();
      job = data;
    }
    if (!job && customerId) {
      const { data } = await supabase
        .from('jobs')
        .select('id, stage, org_id')
        .eq('customer_id', customerId)
        .order('created_at', { ascending: false })
        .limit(1)
        .single();
      job = data;
    }
    if (!job) {
      console.log('[advanceDealStage] No job found for quote:', quoteId, 'customer:', customerId);
      return;
    }

    // Already at the target stage
    if (job.stage === targetStageId) return;

    // Get sort_order for current and target stages
    const { data: stages } = await supabase
      .from('job_stages')
      .select('stage_id, sort_order')
      .eq('org_id', job.org_id)
      .in('stage_id', [job.stage, targetStageId]);

    if (!stages || stages.length < 2) {
      console.log('[advanceDealStage] Could not find both stages:', job.stage, targetStageId);
      return;
    }

    const currentOrder = stages.find(s => s.stage_id === job.stage)?.sort_order;
    const targetOrder = stages.find(s => s.stage_id === targetStageId)?.sort_order;

    if (currentOrder == null || targetOrder == null) return;

    // Only move forward
    if (currentOrder >= targetOrder) {
      console.log('[advanceDealStage] Skipping: current stage', job.stage, '(order', currentOrder, ') >= target', targetStageId, '(order', targetOrder, ')');
      return;
    }

    const { error: updateError } = await supabase
      .from('jobs')
      .update({ stage: targetStageId, updated_at: new Date().toISOString() })
      .eq('id', job.id);

    if (updateError) {
      console.error('[advanceDealStage] Failed to update job stage:', updateError);
    } else {
      console.log('[advanceDealStage] Advanced job', job.id, 'from', job.stage, 'to', targetStageId);
    }
  } catch (err) {
    console.error('[advanceDealStage] Error:', err);
  }
}

// Email the business owner when a customer accepts a quote (same style as the
// new-lead and new-appointment notifications). Never throws — acceptance must
// not fail because of an email problem. Skips if a notification was already
// sent for this quote (Stripe webhook + verify-checkout can both fire).
async function notifyQuoteAccepted(supabase, quoteId, { paymentMethod, amountPaid } = {}) {
  try {
    const { data: quoteOrg } = await supabase.from('quotes').select('org_id').eq('id', quoteId).maybeSingle();
    if (!quoteOrg) return;
    const orgId = quoteOrg.org_id;
    const [company, notifications] = await Promise.all([
      getOrgSetting(supabase, orgId, 'company'),
      getOrgSetting(supabase, orgId, 'notifications')
    ]);
    if (notifications.quote_accepted === false) {
      console.log('[notifyQuoteAccepted] Quote accepted notifications disabled');
      return;
    }
    const notificationEmail = company.notification_email || company.email;
    if (!notificationEmail) {
      console.log('[notifyQuoteAccepted] No notification email configured');
      return;
    }

    const { data: quote } = await supabase
      .from('quotes')
      .select('id, quote_number, title, total, customer_id, selected_package_id, accepted_at')
      .eq('id', quoteId)
      .single();
    if (!quote) return;

    const quoteLabel = quote.quote_number ? `#${quote.quote_number}` : quote.id;

    // Don't send twice for the same quote
    const { data: already } = await supabase
      .from('email_logs')
      .select('id')
      .eq('org_id', orgId)
      .eq('email_type', 'quote_accepted_notification')
      .eq('status', 'sent')
      .ilike('subject', `%${quoteLabel}%`)
      .limit(1);
    if (already && already.length > 0) {
      console.log('[notifyQuoteAccepted] Already notified for quote', quoteLabel);
      return;
    }

    const [{ data: customer }, { data: optionalItems }, pkgRes] = await Promise.all([
      supabase.from('customers').select('name, email, phone, address, city, state, zip').eq('id', quote.customer_id).maybeSingle(),
      supabase.from('quote_line_items').select('description, line_total, is_selected')
        .eq('quote_id', quote.id).eq('is_optional', true).order('sort_order'),
      quote.selected_package_id
        ? supabase.from('quote_packages').select('name').eq('id', quote.selected_package_id).maybeSingle()
        : Promise.resolve({ data: null })
    ]);

    const money = (n) => `$${(parseFloat(n) || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    const customerName = customer?.name || 'Customer';
    const companyName = company.name || 'Your business';
    const siteUrl = getSiteUrl();

    const emailSubject = `✅ Quote Accepted: ${customerName} - ${quoteLabel}${quote.title ? ' ' + quote.title : ''}`;

    let emailBody = `Good news! A customer accepted a quote.\n\n`;
    emailBody += `=== Quote ===\n`;
    emailBody += `Quote: ${quoteLabel}${quote.title ? ' - ' + quote.title : ''}\n`;
    emailBody += `Total: ${money(quote.total)}\n`;
    if (pkgRes?.data?.name) emailBody += `Package Selected: ${pkgRes.data.name}\n`;
    if (paymentMethod === 'card') {
      emailBody += `Payment: Paid by card online${amountPaid ? ` (${money(amountPaid)} deposit received)` : ''}\n`;
    } else if (paymentMethod === 'check') {
      emailBody += `Payment: Will pay by check (deposit not yet received)\n`;
    }

    const opts = optionalItems || [];
    if (opts.length > 0) {
      const added = opts.filter(i => i.is_selected);
      const declined = opts.filter(i => !i.is_selected);
      emailBody += `\n=== Optional Items ===\n`;
      emailBody += added.length
        ? added.map(i => `Added: ${i.description} (${money(i.line_total)})`).join('\n') + '\n'
        : `None added\n`;
      if (declined.length) {
        emailBody += declined.map(i => `Not added: ${i.description}`).join('\n') + '\n';
      }
    }

    emailBody += `\n=== Customer ===\n`;
    emailBody += `Name: ${customerName}\n`;
    emailBody += `Email: ${customer?.email || 'Not provided'}\n`;
    emailBody += `Phone: ${customer?.phone || 'Not provided'}\n`;
    if (customer?.address) {
      emailBody += `Address: ${customer.address}${customer.city ? ', ' + customer.city : ''}${customer.state ? ', ' + customer.state : ''} ${customer.zip || ''}\n`;
    }

    emailBody += `\nAccepted: ${new Date(quote.accepted_at || Date.now()).toLocaleString('en-US', { timeZone: 'America/New_York' })}\n`;
    emailBody += `\n---\nView the quote: ${siteUrl}/admin/quote-detail.html?id=${quote.id}`;

    let emailStatus = 'sent';
    let emailError = null;

    if (process.env.RESEND_API_KEY) {
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${process.env.RESEND_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          from: platformFrom(companyName),
          to: [notificationEmail],
          subject: emailSubject,
          text: emailBody
        })
      });
      if (!res.ok) {
        emailError = await res.text();
        emailStatus = 'failed';
        console.error('[notifyQuoteAccepted] Resend error:', emailError);
      }
    } else if (process.env.SENDGRID_API_KEY) {
      const res = await fetch('https://api.sendgrid.com/v3/mail/send', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${process.env.SENDGRID_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          personalizations: [{ to: [{ email: notificationEmail }] }],
          from: { email: process.env.EMAIL_FROM, name: companyName },
          subject: emailSubject,
          content: [{ type: 'text/plain', value: emailBody }]
        })
      });
      if (!(res.ok || res.status === 202)) {
        emailError = await res.text();
        emailStatus = 'failed';
        console.error('[notifyQuoteAccepted] SendGrid error:', emailError);
      }
    } else {
      console.log('[notifyQuoteAccepted] No email provider configured. Would send to:', notificationEmail);
      emailStatus = 'failed';
      emailError = 'No email provider configured';
    }

    try {
      await supabase.from('email_logs').insert({
        org_id: orgId,
        customer_id: quote.customer_id,
        to_email: notificationEmail,
        subject: emailSubject,
        body: emailBody,
        status: emailStatus,
        error_message: emailError,
        email_type: 'quote_accepted_notification'
      });
    } catch (logErr) {
      console.error('[notifyQuoteAccepted] Failed to log email:', logErr);
    }
  } catch (err) {
    console.error('[notifyQuoteAccepted] Error:', err);
  }
}

module.exports = {
  notifyQuoteAccepted,
  signToken,
  verifyToken,
  getOrgBySlug,
  getPlatformStripe,
  getOrgStripe,
  getUserClient,
  getBearerToken,
  requireStaff,
  getOrgSetting,
  getSiteUrl,
  platformFrom,
  getSupabase,
  success,
  error,
  handleCors,
  parseBody,
  getSessionToken,
  validateSession,
  setSessionCookie,
  clearSessionCookie,
  generateToken,
  advanceDealStage,
};
