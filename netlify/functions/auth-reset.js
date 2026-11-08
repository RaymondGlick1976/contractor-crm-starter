// =============================================
// AUTH RESET - email a password-reset link (sent through Resend, not Supabase's mailer)
// POST { email }  → always 200 so the endpoint can't be used to discover accounts
// =============================================

const { getSupabase, success, error, handleCors, parseBody, getSiteUrl, platformFrom } = require('./utils');

exports.handler = async (event) => {
  const cors = handleCors(event);
  if (cors) return cors;
  if (event.httpMethod !== 'POST') return error('Method not allowed', 405);

  const email = String(parseBody(event).email || '').trim().toLowerCase();
  const ok = success({ message: 'If that email has an account, a reset link is on its way.' });
  if (!email) return ok;

  try {
    const admin = getSupabase();
    const { data, error: linkErr } = await admin.auth.admin.generateLink({ type: 'recovery', email });
    if (linkErr || !data?.properties?.hashed_token) return ok; // unknown email → same response

    const link = `${getSiteUrl()}/admin/reset-password.html?token_hash=${encodeURIComponent(data.properties.hashed_token)}`;

    if (process.env.RESEND_API_KEY) {
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${process.env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: platformFrom('YourCRM'),
          to: [email],
          subject: 'Reset your YourCRM password',
          html: `
            <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1e293b">
              <h2 style="margin:0 0 12px">Reset your password</h2>
              <p>Someone (hopefully you) asked to reset the password for <strong>${email}</strong>.</p>
              <p style="margin:28px 0"><a href="${link}" style="background:#3e855f;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:600">Choose a new password</a></p>
              <p style="color:#64748b;font-size:14px">This link expires in 1 hour. If you didn't ask for this, you can ignore this email.</p>
            </div>`,
          text: `Reset your YourCRM password: ${link}\n\nThis link expires in 1 hour.`
        })
      });
      if (!res.ok) console.error('[auth-reset] Resend error:', await res.text());
    } else {
      console.log('[auth-reset] RESEND_API_KEY not set. Reset link:', link);
    }
    return ok;
  } catch (err) {
    console.error('[auth-reset] error:', err);
    return ok;
  }
};
