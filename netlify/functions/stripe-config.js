// =============================================
// STRIPE CONFIG - publishable key + the business's connected account
// Card payments are available only when that business has finished Stripe onboarding.
//   GET ?token=<quote or invoice access token>   (public links)
//   GET with portal session cookie              (customer portal)
// =============================================

const { getSupabase, success, error, handleCors, validateSession, getOrgStripe } = require('./utils');

exports.handler = async (event) => {
  const corsResponse = handleCors(event);
  if (corsResponse) return corsResponse;

  const supabase = getSupabase();
  let orgId = null;

  const token = event.queryStringParameters?.token;
  if (token) {
    const { data: invoice } = await supabase.from('invoices').select('org_id').eq('access_token', token).maybeSingle();
    if (invoice) orgId = invoice.org_id;
    else {
      const { data: quote } = await supabase.from('quotes').select('org_id').eq('access_token', token).maybeSingle();
      if (!quote) return error('Invalid token', 401);
      orgId = quote.org_id;
    }
  } else {
    const customer = await validateSession(event);
    if (!customer) return error('Unauthorized', 401);
    orgId = customer.org_id;
  }

  const { account, ready } = await getOrgStripe(supabase, orgId);
  if (!ready || !process.env.STRIPE_PUBLISHABLE_KEY) {
    return success({ enabled: false, publishableKey: null, stripeAccount: null });
  }
  return success({ enabled: true, publishableKey: process.env.STRIPE_PUBLISHABLE_KEY, stripeAccount: account });
};
