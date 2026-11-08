// =============================================
// STRIPE WEBHOOK - Handle Stripe events
// =============================================

// Registered in Stripe as a Connect webhook ("events on connected accounts"),
// so every event carries event.account = the business's connected account.
const { buildInvoiceLines, invoiceHeaderFromQuote, insertInvoiceLines } = require('./invoice-builder');
const { Resend } = require('resend');
const { getSupabase, success, error, notifyQuoteAccepted, getPlatformStripe, getOrgSetting, getSiteUrl, platformFrom } = require('./utils');

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return error('Method not allowed', 405);
  }
  
  const stripe = getPlatformStripe();
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!stripe || !webhookSecret) return error('Stripe not configured', 503);
  
  let stripeEvent;
  
  try {
    const sig = event.headers['stripe-signature'];
    stripeEvent = stripe.webhooks.constructEvent(event.body, sig, webhookSecret);
  } catch (err) {
    console.error('Webhook signature verification failed:', err.message);
    return error(`Webhook Error: ${err.message}`, 400);
  }
  
  const supabase = getSupabase();

  try {
    // Which business is this event for?
    const accountId = stripeEvent.account || null;
    let org = null;
    if (accountId) {
      const { data } = await supabase.from('organizations')
        .select('id, stripe_account_id').eq('stripe_account_id', accountId).maybeSingle();
      org = data;
    }

    // Business finished/changed Stripe onboarding
    if (stripeEvent.type === 'account.updated') {
      const acct = stripeEvent.data.object;
      await supabase.from('organizations').update({
        stripe_charges_enabled: !!acct.charges_enabled,
        stripe_details_submitted: !!acct.details_submitted
      }).eq('stripe_account_id', acct.id);
      return success({ received: true });
    }
    if (stripeEvent.type === 'account.application.deauthorized') {
      if (accountId) {
        await supabase.from('organizations').update({
          stripe_account_id: null, stripe_charges_enabled: false, stripe_details_submitted: false
        }).eq('stripe_account_id', accountId);
      }
      return success({ received: true });
    }

    if (!org) {
      console.log('[stripe-webhook] Event for unknown/unlinked account, ignoring:', stripeEvent.type, accountId);
      return success({ received: true, ignored: true });
    }

    const obj = stripeEvent.data.object;
    // Metadata written by our own functions must point at the same business
    if (obj.metadata?.org_id && obj.metadata.org_id !== org.id) {
      console.error('[stripe-webhook] org mismatch — ignoring', obj.metadata.org_id, org.id);
      return success({ received: true, ignored: true });
    }

    switch (stripeEvent.type) {
      case 'checkout.session.completed':
        await handleCheckoutComplete(supabase, obj, org.id);
        break;
      case 'payment_intent.succeeded':
        await handlePaymentSuccess(supabase, obj, org.id);
        break;
      case 'payment_intent.payment_failed':
        await handlePaymentFailed(supabase, obj, org.id);
        break;
    }
    
    return success({ received: true });
    
  } catch (err) {
    console.error('Webhook handler error:', err);
    return error('Webhook handler failed', 500);
  }
};

async function handleCheckoutComplete(supabase, session, orgId) {
  const { quote_id, customer_id, payment_type } = session.metadata;

  console.log('handleCheckoutComplete:', { quote_id, customer_id, payment_type, amount: session.amount_total });

  if (!quote_id) {
    console.error('No quote_id in session metadata');
    return;
  }

  // Get quote
  const { data: quote, error: quoteError } = await supabase
    .from('quotes')
    .select('*')
    .eq('id', quote_id)
    .eq('org_id', orgId)
    .single();

  if (quoteError || !quote) {
    console.error('Quote not found:', quote_id, quoteError);
    return;
  }

  // CRITICAL: Update quote status first - this must succeed
  const { error: statusError } = await supabase
    .from('quotes')
    .update({
      status: 'accepted',
      accepted_at: new Date().toISOString(),
    })
    .eq('id', quote_id);

  if (statusError) {
    console.error('CRITICAL: Failed to update quote status:', statusError);
    throw statusError; // Only throw for the critical operation
  }

  console.log('Quote marked as accepted:', quote_id);

  // Create invoice from quote (non-critical - don't crash webhook)
  let invoice = null;
  try {
    const { data: invoiceNumber } = await supabase.rpc('generate_invoice_number', { p_org: orgId });

    const { data: inv, error: invError } = await supabase
      .from('invoices')
      .insert({
        invoice_number: invoiceNumber,
        quote_id,
        customer_id: quote.customer_id,
        title: quote.title,
        status: 'partial',
        subtotal: quote.subtotal,
        tax_rate: quote.tax_rate,
        tax_amount: quote.tax_amount,
        total: quote.total,
        amount_paid: session.amount_total / 100,
        amount_due: quote.total - (session.amount_total / 100),
        due_date: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString().split('T')[0],
        sent_at: new Date().toISOString(),
        ...invoiceHeaderFromQuote(quote),
      })
      .select()
      .single();

    if (invError) {
      console.error('Failed to create invoice:', invError);
    } else {
      invoice = inv;
      console.log('Invoice created:', invoice.invoice_number);
    }

    // Copy line items to invoice (selected bundle's items when the quote has bundles)
    if (invoice) {
      const { lineItems } = await buildInvoiceLines(supabase, quote);
      await insertInvoiceLines(supabase, invoice.id, lineItems);
    }
  } catch (invoiceErr) {
    console.error('Invoice creation error (non-fatal):', invoiceErr);
  }

  // Record payment (non-critical)
  try {
    if (invoice) {
      await supabase
        .from('payments')
        .insert({
          org_id: orgId,
          invoice_id: invoice.id,
          customer_id: quote.customer_id,
          amount: session.amount_total / 100,
          payment_type: 'deposit',
          stripe_payment_intent_id: session.payment_intent,
          status: 'succeeded',
        });
      console.log('Payment recorded');
    }
  } catch (payErr) {
    console.error('Payment recording error (non-fatal):', payErr);
  }

  // Email the owner that the quote was accepted (non-blocking, skips if already sent)
  await notifyQuoteAccepted(supabase, quote_id, { paymentMethod: 'card', amountPaid: session.amount_total / 100 });

  // Queue notifications (non-critical)
  try {
    await supabase.from('notification_queue').insert([
      {
        customer_id: quote.customer_id,
        notification_type: 'quote_accepted',
        reference_type: 'quote',
        reference_id: quote_id,
        is_admin_notification: true,
      },
      ...(invoice ? [{
        customer_id: quote.customer_id,
        notification_type: 'payment_received',
        reference_type: 'payment',
        reference_id: invoice.id,
      }] : []),
    ]);
  } catch (notifErr) {
    console.error('Notification queue error (non-fatal):', notifErr);
  }

  // Send confirmation emails (non-critical)
  try {
    if (invoice) {
      await sendPaymentConfirmation(supabase, quote.customer_id, session.amount_total / 100, invoice);
    }
  } catch (emailErr) {
    console.error('Email send error (non-fatal):', emailErr);
  }
}

async function handlePaymentSuccess(supabase, paymentIntent, orgId) {
  const { invoice_id } = paymentIntent.metadata || {};
  
  if (!invoice_id) return;
  
  // Update payment record
  await supabase
    .from('payments')
    .update({ status: 'succeeded' })
    .eq('org_id', orgId)
    .eq('stripe_payment_intent_id', paymentIntent.id);
  
  // Get invoice to recalculate
  const { data: invoice } = await supabase
    .from('invoices')
    .select('*')
    .eq('id', invoice_id)
    .eq('org_id', orgId)
    .single();
  
  if (invoice) {
    const paymentAmount = paymentIntent.amount / 100;

    // DB triggers (sync_payment_to_allocations → recalculate_invoice_payments)
    // already updated amount_paid/amount_due/status when we set payment status above.
    // Just re-read the invoice for the email.
    const { data: updatedInvoice } = await supabase
      .from('invoices')
      .select('*')
      .eq('id', invoice_id)
      .single();

    // Send confirmation
    try {
      await sendPaymentConfirmation(supabase, invoice.customer_id, paymentAmount, updatedInvoice || invoice);
    } catch (emailErr) {
      console.error('Failed to send payment confirmation email:', emailErr);
    }
  }
}

async function handlePaymentFailed(supabase, paymentIntent, orgId) {
  await supabase
    .from('payments')
    .update({ status: 'failed' })
    .eq('org_id', orgId)
    .eq('stripe_payment_intent_id', paymentIntent.id);
}

async function sendPaymentConfirmation(supabase, customerId, amount, invoice) {
  // Get customer
  const { data: customer } = await supabase
    .from('customers')
    .select('*')
    .eq('id', customerId)
    .single();

  if (!customer || !process.env.RESEND_API_KEY) return;

  const company = await getOrgSetting(supabase, invoice.org_id, 'company');
  const branding = await getOrgSetting(supabase, invoice.org_id, 'branding');
  const companyName = company.name || 'Your contractor';
  const brandColor = /^#[0-9a-f]{3,8}$/i.test(branding.color || '') ? branding.color : '#3e855f';
  const replyTo = company.email || company.from_email || null;
  const notifyTo = company.notification_email || company.email || null;
  const esc = (v) => String(v == null ? '' : v).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  const resend = new Resend(process.env.RESEND_API_KEY);

  // Email to customer
  await resend.emails.send({
    from: platformFrom(companyName),
    ...(replyTo ? { reply_to: replyTo } : {}),
    to: customer.email,
    subject: `Payment Confirmation - ${companyName}`,
    html: `
      <div style="font-family: 'Segoe UI', Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <div style="background: ${brandColor}; padding: 30px; text-align: center;">
          <h1 style="color: #fff; margin: 0; font-weight: 600;">Payment Received</h1>
          <p style="color: rgba(255,255,255,0.8); margin: 5px 0 0; font-size: 14px;">Thank you for your payment!</p>
        </div>
        <div style="padding: 30px; background: #f8fafc;">
          <p style="color: #1e293b;">Hi ${customer.name.split(' ')[0]},</p>
          <p style="color: #475569;">Thank you for your payment of <strong style="color: ${brandColor};">$${amount.toFixed(2)}</strong>.</p>
          <div style="background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 20px; margin: 20px 0;">
            <p style="margin: 5px 0; color: #475569;"><strong>Invoice:</strong> ${invoice.invoice_number}</p>
            <p style="margin: 5px 0; color: #475569;"><strong>Remaining Balance:</strong> <span style="color: ${parseFloat(invoice.amount_due) > 0 ? '#ef4444' : '#10b981'}; font-weight: bold;">$${parseFloat(invoice.amount_due).toFixed(2)}</span></p>
          </div>
          <p style="color: #475569;">You can view your invoice and payment history in your <a href="${getSiteUrl()}/portal/invoices.html" style="color: ${brandColor};">customer portal</a>.</p>
          <p style="color: #475569;">Thank you for choosing ${esc(companyName)}!</p>
        </div>
        <div style="padding: 20px; text-align: center; background: #1e293b; color: #94a3b8; font-size: 12px;">
          <p style="margin: 0;">${esc(companyName)}</p>
        </div>
      </div>
    `,
  });
  
  // Email to the business
  if (notifyTo) {
    await resend.emails.send({
      from: platformFrom('YourCRM'),
      to: notifyTo,
      subject: `Payment Received: $${amount.toFixed(2)} from ${customer.name}`,
      html: `
        <p>Payment received from ${customer.name} (${customer.email})</p>
        <p><strong>Amount:</strong> $${amount.toFixed(2)}</p>
        <p><strong>Invoice:</strong> ${invoice.invoice_number}</p>
        <p><strong>Remaining Balance:</strong> $${parseFloat(invoice.amount_due).toFixed(2)}</p>
      `,
    });
  }
}
