// =============================================
// GOOGLE CALENDAR CALLBACK - Google redirects here after the business approves access.
// The signed `state` tells us which business is connecting.
// =============================================

const { getSupabase, verifyToken, getSiteUrl } = require('./utils');
const { redirectUri } = require('./gcal-utils');

const back = (qs) => ({ statusCode: 302, headers: { Location: `${getSiteUrl()}/admin/settings.html?${qs}#calendar` } });

exports.handler = async (event) => {
  const { code, state, error: oauthError } = event.queryStringParameters || {};
  if (oauthError) return back(`gcal_error=${encodeURIComponent(oauthError)}`);

  const st = verifyToken(state);
  if (!code || !st || st.purpose !== 'gcal' || !st.org_id) return back('gcal_error=invalid_request');
  if (!process.env.GOOGLE_CLIENT_ID || !process.env.GOOGLE_CLIENT_SECRET) return back('gcal_error=not_configured');

  try {
    const res = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: redirectUri(),
        client_id: process.env.GOOGLE_CLIENT_ID,
        client_secret: process.env.GOOGLE_CLIENT_SECRET
      })
    });
    const tokens = await res.json();
    if (!res.ok || tokens.error || !tokens.refresh_token) {
      console.error('Google token exchange error:', tokens);
      return back('gcal_error=token_exchange_failed');
    }

    const supabase = getSupabase();
    // The person who started the flow must still be a member of that business
    const { data: member } = await supabase.from('app_users').select('id')
      .eq('org_id', st.org_id).eq('user_id', st.uid).eq('is_active', true).maybeSingle();
    if (!member) return back('gcal_error=not_allowed');

    const { error: upErr } = await supabase.from('google_calendar_connection').upsert({
      org_id: st.org_id,
      calendar_id: 'primary',
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      token_expires_at: new Date(Date.now() + tokens.expires_in * 1000).toISOString(),
      connected_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    }, { onConflict: 'org_id' });
    if (upErr) {
      console.error('Failed to save GCal connection:', upErr);
      return back('gcal_error=save_failed');
    }
    return back('gcal_connected=1');
  } catch (err) {
    console.error('GCal callback error:', err);
    return back('gcal_error=unexpected');
  }
};
