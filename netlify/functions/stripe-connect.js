// =============================================
// STRIPE CONNECT - link a business's own Stripe account (Settings → Online Payments)
//   GET               → current status (refreshed from Stripe)
//   POST {action:'onboard'}    → create/continue Stripe onboarding, returns { url }
//   POST {action:'dashboard'}  → returns a link to the business's Stripe dashboard
//   POST {action:'disconnect'} → unlink (the Stripe account itself is untouched)
// Requires a staff member with Settings access.
// =============================================

const { success, error, handleCors, parseBody, requireStaff, getPlatformStripe, getOrgSetting, getSiteUrl } = require('./utils');

function statusFrom(org) {
  return {
    configured: !!process.env.STRIPE_SECRET_KEY,
    connected: !!org?.stripe_account_id,
    charges_enabled: !!org?.stripe_charges_enabled,
    details_submitted: !!org?.stripe_details_submitted,
    account_id: org?.stripe_account_id || null,
    connected_at: org?.stripe_connected_at || null
  };
}

exports.handler = async (event) => {
  const cors = handleCors(event);
  if (cors) return cors;

  const auth = await requireStaff(event, 'can_access_settings');
  if (auth.response) return auth.response;

  const stripe = getPlatformStripe();
  const admin = auth.admin; // service role: only server code may write the Stripe link
  const orgId = auth.orgId;

  const loadOrg = async () => (await admin.from('organizations')
    .select('id, name, stripe_account_id, stripe_charges_enabled, stripe_details_submitted, stripe_connected_at')
    .eq('id', orgId).single()).data;

  try {
    let org = await loadOrg();

    // Refresh flags from Stripe whenever we have an account
    const refresh = async () => {
      if (!stripe || !org?.stripe_account_id) return;
      const acct = await stripe.accounts.retrieve(org.stripe_account_id);
      const patch = { stripe_charges_enabled: !!acct.charges_enabled, stripe_details_submitted: !!acct.details_submitted };
      await admin.from('organizations').update(patch).eq('id', orgId);
      org = { ...org, ...patch };
    };

    if (event.httpMethod === 'GET') {
      try { await refresh(); } catch (e) { console.error('[stripe-connect] refresh failed:', e.message); }
      return success(statusFrom(org));
    }
    if (event.httpMethod !== 'POST') return error('Method not allowed', 405);
    if (!stripe) return error('Online payments are not configured on this YourCRM server yet.', 503);

    const { action } = parseBody(event);
    const site = getSiteUrl();

    if (action === 'onboard') {
      if (!org.stripe_account_id) {
        const company = await getOrgSetting(admin, orgId, 'company');
        const acct = await stripe.accounts.create({
          type: 'standard',
          email: company.email || auth.user.email,
          business_profile: { name: company.name || org.name, url: company.website || undefined },
          metadata: { crm_org_id: orgId }
        });
        await admin.from('organizations').update({
          stripe_account_id: acct.id, stripe_connected_at: new Date().toISOString(),
          stripe_charges_enabled: !!acct.charges_enabled, stripe_details_submitted: !!acct.details_submitted
        }).eq('id', orgId);
        org = await loadOrg();
      }
      const link = await stripe.accountLinks.create({
        account: org.stripe_account_id,
        type: 'account_onboarding',
        refresh_url: `${site}/admin/settings.html?stripe=refresh#payments`,
        return_url: `${site}/admin/settings.html?stripe=return#payments`
      });
      return success({ url: link.url });
    }

    if (action === 'dashboard') {
      // Standard accounts manage everything in their own Stripe dashboard
      return success({ url: 'https://dashboard.stripe.com/' });
    }

    if (action === 'disconnect') {
      await admin.from('organizations').update({
        stripe_account_id: null, stripe_charges_enabled: false, stripe_details_submitted: false, stripe_connected_at: null
      }).eq('id', orgId);
      return success(statusFrom(null));
    }

    return error('Unknown action');
  } catch (err) {
    console.error('[stripe-connect] error:', err);
    return error(err.message || 'Stripe request failed', 500);
  }
};
