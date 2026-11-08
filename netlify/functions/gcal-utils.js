// =============================================
// GOOGLE CALENDAR API UTILITIES — one connection per business (org)
// (not an endpoint)
// =============================================

const { createClient } = require('@supabase/supabase-js');

const admin = () => createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

function redirectUri() {
  const site = (process.env.SITE_URL || 'https://your-site.netlify.app').replace(/\/+$/, '');
  return process.env.GOOGLE_REDIRECT_URI || `${site}/.netlify/functions/gcal-callback`;
}

async function refreshAccessToken(refreshToken) {
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: process.env.GOOGLE_CLIENT_ID,
      client_secret: process.env.GOOGLE_CLIENT_SECRET
    })
  });
  const tokens = await response.json();
  if (!response.ok || tokens.error) {
    throw new Error('Failed to refresh Google token: ' + (tokens.error_description || tokens.error));
  }
  return tokens;
}

// Connection for a business, refreshing the access token when it's about to expire
async function getGCalConnection(orgId) {
  if (!orgId) throw new Error('Google Calendar not connected');
  const db = admin();
  const { data: connection } = await db.from('google_calendar_connection')
    .select('*').eq('org_id', orgId).maybeSingle();
  if (!connection) throw new Error('Google Calendar not connected');

  if (new Date(connection.token_expires_at) - Date.now() < 5 * 60 * 1000) {
    const t = await refreshAccessToken(connection.refresh_token);
    const patch = {
      access_token: t.access_token,
      refresh_token: t.refresh_token || connection.refresh_token,
      token_expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(),
      updated_at: new Date().toISOString()
    };
    await db.from('google_calendar_connection').update(patch).eq('id', connection.id);
    Object.assign(connection, patch);
  }
  return connection;
}

// Authenticated Google Calendar API call on behalf of a business
async function gcalRequest(orgId, method, path, body = null) {
  const connection = await getGCalConnection(orgId);
  const options = {
    method,
    headers: {
      Authorization: `Bearer ${connection.access_token}`,
      Accept: 'application/json',
      'Content-Type': 'application/json'
    }
  };
  if (body) options.body = JSON.stringify(body);
  const response = await fetch(`https://www.googleapis.com/calendar/v3${path}`, options);
  if (response.status === 204) return null;
  const data = await response.json();
  if (!response.ok) {
    console.error('GCal API Error:', data);
    throw new Error(data.error?.message || 'Google Calendar API error');
  }
  return data;
}

async function getConnectionStatus(orgId) {
  const { data: c } = await admin().from('google_calendar_connection')
    .select('calendar_id, connected_at').eq('org_id', orgId).maybeSingle();
  return c ? { connected: true, calendarId: c.calendar_id || 'primary', connectedAt: c.connected_at } : { connected: false };
}

module.exports = { getGCalConnection, refreshAccessToken, gcalRequest, getConnectionStatus, redirectUri };
