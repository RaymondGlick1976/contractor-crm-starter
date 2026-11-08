// =============================================
// GOOGLE CALENDAR CONNECT (Settings → Google Calendar)
//   GET                         → { configured, connected, calendarId, connectedAt }
//   POST {action:'auth'}        → { authUrl }  (signed state names this business)
//   POST {action:'disconnect'}
// Requires a staff member with Settings access.
// =============================================

const { success, error, handleCors, parseBody, requireStaff, signToken } = require('./utils');
const { getConnectionStatus, redirectUri } = require('./gcal-utils');

exports.handler = async (event) => {
  const cors = handleCors(event);
  if (cors) return cors;

  const auth = await requireStaff(event, 'can_access_settings');
  if (auth.response) return auth.response;
  const configured = !!(process.env.GOOGLE_CLIENT_ID && process.env.GOOGLE_CLIENT_SECRET);

  if (event.httpMethod === 'GET') {
    return success({ configured, ...(await getConnectionStatus(auth.orgId)) });
  }
  if (event.httpMethod !== 'POST') return error('Method not allowed', 405);

  const { action } = parseBody(event);

  if (action === 'auth') {
    if (!configured) return error('Google Calendar is not configured on this YourCRM server yet.', 503);
    const state = signToken({ org_id: auth.orgId, uid: auth.user.id, purpose: 'gcal' }, 15 * 60 * 1000);
    const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
    url.searchParams.set('client_id', process.env.GOOGLE_CLIENT_ID);
    url.searchParams.set('redirect_uri', redirectUri());
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('scope', 'https://www.googleapis.com/auth/calendar.events');
    url.searchParams.set('access_type', 'offline');
    url.searchParams.set('prompt', 'consent');
    url.searchParams.set('state', state);
    return success({ authUrl: url.toString() });
  }

  if (action === 'disconnect') {
    const { error: delErr } = await auth.admin.from('google_calendar_connection').delete().eq('org_id', auth.orgId);
    if (delErr) return error(delErr.message, 500);
    return success({ connected: false, configured });
  }

  return error('Unknown action');
};
