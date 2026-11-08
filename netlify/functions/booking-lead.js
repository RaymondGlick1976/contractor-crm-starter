// =============================================
// BOOKING LEAD - prefill the scheduling page for someone who just submitted a booking form
// GET ?token=<signed token from booking-submit>
// =============================================

const { getSupabase, verifyToken } = require('./utils');

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Content-Type': 'application/json'
  };
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers, body: '' };
  if (event.httpMethod !== 'GET') return { statusCode: 405, headers, body: JSON.stringify({ error: 'Method not allowed' }) };

  const payload = verifyToken(event.queryStringParameters?.token);
  // Expired/invalid → schedule page still works on its own
  if (!payload || !payload.deal_id) {
    return { statusCode: 200, headers, body: JSON.stringify({ customer: null, form: null, expired: true }) };
  }

  try {
    const supabase = getSupabase();
    const { data: deal } = await supabase
      .from('jobs')
      .select('id, org_id, customer_id, customers(id, name, email, phone), organizations(slug)')
      .eq('id', payload.deal_id)
      .maybeSingle();
    if (!deal || (payload.org_id && deal.org_id !== payload.org_id)) {
      return { statusCode: 404, headers, body: JSON.stringify({ error: 'Lead not found' }) };
    }

    let form = null;
    if (payload.form_id) {
      const { data } = await supabase.from('booking_forms')
        .select('thank_you_title, thank_you_message, thank_you_redirect_url, primary_color')
        .eq('id', payload.form_id).eq('org_id', deal.org_id).maybeSingle();
      form = data;
    }

    const c = deal.customers;
    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        org: deal.organizations?.slug || null,
        customer: c ? { name: c.name, email: c.email, phone: c.phone } : null,
        form
      })
    };
  } catch (err) {
    console.error('Booking lead error:', err.message);
    return { statusCode: 500, headers, body: JSON.stringify({ error: 'Server error' }) };
  }
};
