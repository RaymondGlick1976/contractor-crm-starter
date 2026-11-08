// =============================================
// PORTAL LOGIN - Send Magic Link(s)
// The same email can be a customer of more than one business on YourCRM,
// so we send one link per business (each link opens that business's portal).
// =============================================

const { Resend } = require('resend');
const { getSupabase, success, error, handleCors, parseBody, generateToken, getOrgSetting, getSiteUrl, platformFrom } = require('./utils');

const esc = (v) => String(v == null ? '' : v).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

exports.handler = async (event) => {
  const corsResponse = handleCors(event);
  if (corsResponse) return corsResponse;
  if (event.httpMethod !== 'POST') return error('Method not allowed', 405);

  const { email, org } = parseBody(event);
  if (!email) return error('Email is required');

  const supabase = getSupabase();
  const generic = success({ message: 'If an account exists, a login link has been sent.' });

  try {
    let q = supabase.from('customers').select('id, name, email, org_id').eq('email', email.toLowerCase().trim());
    if (org) {
      const { data: o } = await supabase.from('organizations').select('id').eq('slug', String(org)).maybeSingle();
      if (o) q = q.eq('org_id', o.id);
    }
    const { data: customers } = await q.limit(10);
    if (!customers || customers.length === 0) return generic; // don't reveal whether the email exists

    const resend = new Resend(process.env.RESEND_API_KEY);
    const siteUrl = getSiteUrl();

    for (const customer of customers) {
      const token = generateToken();
      const { error: tokenError } = await supabase.from('auth_tokens').insert({
        org_id: customer.org_id,
        customer_id: customer.id,
        token,
        token_type: 'magic_link',
        expires_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
        ip_address: event.headers['x-forwarded-for'] || event.headers['client-ip'],
        user_agent: event.headers['user-agent'],
      });
      if (tokenError) { console.error('Token creation error:', tokenError); continue; }

      const [company, branding] = await Promise.all([
        getOrgSetting(supabase, customer.org_id, 'company'),
        getOrgSetting(supabase, customer.org_id, 'branding')
      ]);
      const companyName = company.name || 'Your contractor';
      const color = /^#[0-9a-f]{3,8}$/i.test(branding.color || '') ? branding.color : '#3e855f';
      const loginUrl = `${siteUrl}/portal/verify.html?token=${token}`;
      const firstName = (customer.name || '').split(' ')[0] || 'there';

      await resend.emails.send({
        from: platformFrom(companyName),
        ...(company.email ? { reply_to: company.email } : {}),
        to: customer.email,
        subject: `Your login link - ${companyName}`,
        html: `
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #2d2d2d; max-width: 600px; margin: 0 auto; padding: 20px;">
          <div style="background: ${color}; padding: 30px; text-align: center; border-radius: 8px 8px 0 0;">
            <h1 style="color: #ffffff; margin: 0; font-size: 24px;">${esc(companyName)}</h1>
          </div>
          <div style="background: #ffffff; padding: 30px; border: 1px solid #e2e8f0; border-top: none; border-radius: 0 0 8px 8px;">
            <p>Hi ${esc(firstName)},</p>
            <p>Click the button below to open your customer portal with ${esc(companyName)}:</p>
            <div style="text-align: center; margin: 30px 0;">
              <a href="${loginUrl}" style="display: inline-block; background: ${color}; color: #ffffff; padding: 14px 32px; text-decoration: none; border-radius: 6px; font-weight: 600;">Open My Portal</a>
            </div>
            <p style="color: #5a5a5a; font-size: 14px;">This link expires in 1 hour. If you didn't request it, you can ignore this email.</p>
            <hr style="border: none; border-top: 1px solid #e2e8f0; margin: 30px 0;">
            <p style="color: #8a8a8a; font-size: 12px; text-align: center;">${esc(companyName)}${company.phone ? ' · ' + esc(company.phone) : ''}</p>
          </div>
        </body></html>`,
      });
    }

    return success({ message: 'Login link sent successfully' });
  } catch (err) {
    console.error('Login error:', err);
    return error('An error occurred. Please try again.', 500);
  }
};
