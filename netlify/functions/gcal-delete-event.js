// =============================================
// GOOGLE CALENDAR DELETE EVENT (staff) — POST ?event_id=
// =============================================

const { requireStaff } = require('./utils');
const { gcalRequest } = require('./gcal-utils');

const headers = { 'Content-Type': 'application/json' };

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers, body: 'Method not allowed' };
  const auth = await requireStaff(event);
  if (auth.response) return auth.response;

  const eventId = event.queryStringParameters?.event_id;
  if (!eventId) return { statusCode: 400, headers, body: JSON.stringify({ error: 'Missing event_id' }) };
  try {
    await gcalRequest(auth.orgId, 'DELETE', `/calendars/primary/events/${encodeURIComponent(eventId)}`);
    return { statusCode: 200, headers, body: JSON.stringify({ success: true }) };
  } catch (err) {
    console.error('GCal delete event error:', err);
    return { statusCode: 200, headers, body: JSON.stringify({ success: false, error: err.message }) };
  }
};
