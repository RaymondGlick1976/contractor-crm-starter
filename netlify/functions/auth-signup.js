// =============================================
// AUTH SIGNUP
//  A) First-time setup:  { business, name, email, password }
//     → creates the login, THE business (seeded with defaults) and makes them Admin.
//     Single-business app: this only works once. After that, staff join by invitation.
//  B) Invited staff: { inviteToken, name, password }
//     → creates the login for the invited email (the emailed token proves the address).
// The browser then signs in with the password as usual.
// =============================================

const { getSupabase, success, error, handleCors, parseBody } = require('./utils');

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

async function createLogin(admin, email, password, name) {
  const { data, error: err } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: name || '' }
  });
  if (err) {
    const msg = String(err.message || '');
    if (/already|registered|exists/i.test(msg)) return { conflict: true };
    return { err: msg };
  }
  return { user: data.user };
}

exports.handler = async (event) => {
  const cors = handleCors(event);
  if (cors) return cors;
  if (event.httpMethod !== 'POST') return error('Method not allowed', 405);

  const body = parseBody(event);
  const password = String(body.password || '');
  const name = String(body.name || '').trim().slice(0, 100);
  if (password.length < 8) return error('Password must be at least 8 characters.');

  const admin = getSupabase();

  try {
    // ---- B) Invited staff member ----
    if (body.inviteToken) {
      const { data: inv } = await admin.from('invitations')
        .select('id, email, accepted_at, revoked_at, expires_at')
        .eq('token', body.inviteToken).maybeSingle();
      if (!inv || inv.revoked_at || inv.accepted_at || new Date(inv.expires_at) < new Date()) {
        return error('This invitation is no longer valid. Ask your admin to send a new one.', 410);
      }
      const r = await createLogin(admin, inv.email.toLowerCase(), password, name);
      if (r.conflict) return error('You already have a YourCRM login — sign in with your existing password to join.', 409);
      if (r.err) return error(r.err, 400);
      if (name) await admin.from('invitations').update({ name }).eq('id', inv.id);
      await admin.from('profiles').upsert({ user_id: r.user.id, full_name: name || null }, { onConflict: 'user_id' });
      return success({ ok: true });
    }

    // ---- A) First-time setup (one business only) ----
    const { count: orgCount } = await admin.from('organizations').select('id', { count: 'exact', head: true });
    if ((orgCount || 0) > 0) {
      return error('This app is already set up. Sign in, or ask your admin to invite you.', 403);
    }
    const business = String(body.business || '').trim().slice(0, 120);
    const email = String(body.email || '').trim().toLowerCase();
    if (!business) return error('Business name is required.');
    if (!name) return error('Your name is required.');
    if (!EMAIL_RE.test(email)) return error('Enter a valid email address.');

    const r = await createLogin(admin, email, password, name);
    if (r.conflict) return error('An account with this email already exists. Sign in instead.', 409);
    if (r.err) return error(r.err, 400);

    const { data: orgId, error: orgErr } = await admin.rpc('create_organization_for', {
      p_user: r.user.id, p_email: email, p_business: business, p_full_name: name
    });
    if (orgErr) {
      console.error('[auth-signup] org creation failed:', orgErr);
      await admin.auth.admin.deleteUser(r.user.id); // don't leave a login with no business
      return error('Could not set up your business. Please try again.', 500);
    }

    return success({ ok: true, orgId });
  } catch (err) {
    console.error('[auth-signup] error:', err);
    return error('Something went wrong. Please try again.', 500);
  }
};
