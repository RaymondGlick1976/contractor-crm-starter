// =============================================
// PUBLIC INVOICE PAYMENT - Create payment intent by token (no auth)
// =============================================

const { getSupabase, success, error, handleCors, parseBody, getOrgStripe, getSiteUrl } = require('./utils');

exports.handler = async (event) => {
  const corsResponse = handleCors(event);
  if (corsResponse) return corsResponse;

  if (event.httpMethod !== 'POST') {
    return error('Method not allowed', 405);
  }

  const { token, amount } = parseBody(event);

  if (!token || !amount) {
    return error('Token and amount required');
  }

  const supabase = getSupabase();

  try {
    // Get invoice by access token
    const { data: invoice, error: invoiceError } = await supabase
      .from('invoices')
      .select('*, customers(name, email)')
      .eq('access_token', token)
      .single();

    if (invoiceError || !invoice) {
      return error('Invoice not found', 404);
    }

    // Charges go straight to this business's own Stripe account
    const { stripe, account, ready } = await getOrgStripe(supabase, invoice.org_id);
    if (!ready) return error('Online payments are not set up for this business yet. Please choose check/cash or contact them.', 400);

    // Validate amount
    const amountCents = Math.round(amount);
    const maxAmount = Math.round(parseFloat(invoice.amount_due) * 100);

    if (amountCents < 50) {
      return error('Minimum payment is $0.50');
    }

    if (amountCents > maxAmount) {
      return error('Amount exceeds balance due');
    }

    // Create payment intent
    const paymentIntent = await stripe.paymentIntents.create({
      amount: amountCents,
      currency: 'usd',
      metadata: {
        invoice_id: invoice.id,
        customer_id: invoice.customer_id,
        payment_type: 'invoice_payment',
        org_id: invoice.org_id,
      },
      receipt_email: invoice.customers?.email,
    }, { stripeAccount: account });

    // Create pending payment record
    await supabase
      .from('payments')
      .insert({
        invoice_id: invoice.id,
        customer_id: invoice.customer_id,
        amount: amountCents / 100,
        payment_type: 'progress',
        stripe_payment_intent_id: paymentIntent.id,
        status: 'pending',
      });

    return success({ clientSecret: paymentIntent.client_secret, stripeAccount: account });

  } catch (err) {
    console.error('Public payment intent error:', err);
    return error('Failed to create payment', 500);
  }
};
