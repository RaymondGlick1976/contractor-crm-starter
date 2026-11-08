// =============================================
// VERIFY CHECKOUT - Fallback to ensure quote is marked accepted
// Called from thank-you page in case webhook was delayed/failed
// =============================================

const { getSupabase, success, error, handleCors, parseBody, notifyQuoteAccepted, getOrgStripe, getSiteUrl } = require('./utils');

exports.handler = async (event) => {
  const corsResponse = handleCors(event);
  if (corsResponse) return corsResponse;

  if (event.httpMethod !== 'POST') {
    return error('Method not allowed', 405);
  }

  const { session_id, acct } = parseBody(event);

  if (!session_id) {
    return error('Session ID required', 400);
  }

  const supabase = getSupabase();
  const stripe = require('./utils').getPlatformStripe();
  if (!stripe || !acct || !/^acct_[A-Za-z0-9]+$/.test(acct)) return success({ verified: false, reason: 'Missing account' });

  try {
    // Retrieve the checkout session from Stripe
    const session = await stripe.checkout.sessions.retrieve(session_id, { stripeAccount: acct });

    if (session.payment_status !== 'paid') {
      return success({ verified: false, reason: 'Payment not completed' });
    }

    const { quote_id } = session.metadata || {};
    if (!quote_id) {
      return success({ verified: false, reason: 'No quote_id in session' });
    }

    // Check if quote is already accepted
    const { data: quote } = await supabase
      .from('quotes')
      .select('id, status, org_id, organizations(stripe_account_id)')
      .eq('id', quote_id)
      .single();

    // The session must belong to the Stripe account of the quote's business
    if (quote && quote.organizations?.stripe_account_id !== acct) {
      return success({ verified: false, reason: 'Account mismatch' });
    }

    if (!quote) {
      return success({ verified: false, reason: 'Quote not found' });
    }

    if (quote.status === 'accepted') {
      return success({ verified: true, already_accepted: true });
    }

    // Quote not yet accepted - webhook may have failed. Update it now.
    console.log('verify-checkout: Quote not yet accepted, updating now:', quote_id);

    const { error: updateError } = await supabase
      .from('quotes')
      .update({
        status: 'accepted',
        accepted_at: new Date().toISOString(),
      })
      .eq('id', quote_id);

    if (updateError) {
      console.error('verify-checkout: Failed to update quote:', updateError);
      return error('Failed to update quote status', 500);
    }

    console.log('verify-checkout: Quote marked as accepted:', quote_id);

    // Email the owner (skips if the webhook already sent it)
    await notifyQuoteAccepted(supabase, quote_id, { paymentMethod: 'card', amountPaid: session.amount_total / 100 });
    return success({ verified: true, updated: true });

  } catch (err) {
    console.error('verify-checkout error:', err);
    return error('Verification failed', 500);
  }
};
