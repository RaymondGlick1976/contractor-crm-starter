// =============================================
// SEND INVITE - email a staff invitation created in Settings → Users
// POST { invitationId }   (caller must be able to manage users)
// =============================================

const { success, error, handleCors, parseBody, requireStaff, getSiteUrl, platformFrom } = require('./utils');

const esc = (v) => String(v == null ? '' : v).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

exports.handler = async (event) => {
  const cors = handleCors(event);
  if (cors) return cors;
  if (event.httpMethod !== 'POST') return error('Method not allowed', 405);

  const auth = await requireStaff(event, 'can_manage_users');
  if (auth.response) return auth.response;

  const { invitationId } = parseBody(event);
  if (!invitationId) return error('invitationId is required');

  // RLS: only invitations of the caller's business are visible
  const { data: inv } = await auth.db.from('invitations')
    .select('id, email, name, token, expires_at, accepted_at, revoked_at, role:app_roles(name)')
    .eq('id', invitationId).maybeSingle();
  if (!inv) return error('Invitation not found', 404);
  if (inv.accepted_at || inv.revoked_at) return error('This invitation is no longer active', 400);

  const { data: brandingRow } = await auth.db.from('settings').select('value').eq('key', 'branding').maybeSingle();
  const color = /^#[0-9a-f]{3,8}$/i.test(brandingRow?.value?.color || '') ? brandingRow.value.color : '#3e855f';
  const business = auth.org.name;
  const inviter = auth.member.name || 'Your team';
  const link = `${getSiteUrl()}/admin/accept-invite.html?token=${inv.token}`;

  if (!process.env.RESEND_API_KEY) {
    console.log('[send-invite] RESEND_API_KEY not set. Invite link:', link);
    return success({ ok: true, link, emailed: false });
  }

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: platformFrom(business),
      reply_to: auth.user.email,
      to: [inv.email],
      subject: `${inviter} invited you to ${business} on YourCRM`,
      html: `
        <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1e293b">
          <h2 style="margin:0 0 12px">You're invited to ${esc(business)}</h2>
          <p>Hi${inv.name ? ' ' + esc(inv.name.split(' ')[0]) : ''},</p>
          <p>${esc(inviter)} added you to <strong>${esc(business)}</strong>'s workspace on YourCRM${inv.role?.name ? ` as <strong>${esc(inv.role.name)}</strong>` : ''}.</p>
          <p style="margin:28px 0"><a href="${link}" style="background:${color};color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:600">Accept invitation</a></p>
          <p style="color:#64748b;font-size:14px">This invitation expires ${new Date(inv.expires_at).toLocaleDateString('en-US', { month: 'long', day: 'numeric' })}.</p>
        </div>`,
      text: `${inviter} invited you to ${business} on YourCRM. Accept: ${link}`
    })
  });
  if (!res.ok) {
    const t = await res.text();
    console.error('[send-invite] Resend error:', t);
    return error('Could not send the invitation email. You can copy the link instead.', 502);
  }
  return success({ ok: true, link, emailed: true });
};
