// =============================================
// GOOGLE CALENDAR UPDATE EVENT (staff) — POST ?event_id=&date=&time=&title=
// =============================================

const { requireStaff } = require('./utils');
const { gcalRequest } = require('./gcal-utils');

const headers = { 'Content-Type': 'application/json' };

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers, body: 'Method not allowed' };
  const auth = await requireStaff(event);
  if (auth.response) return auth.response;

  const { event_id: eventId, date, time, title } = event.queryStringParameters || {};
  if (!eventId || !date || !time) {
    return { statusCode: 400, headers, body: JSON.stringify({ error: 'Missing event_id, date, or time' }) };
  }
  try {
    const timeZone = auth.org.timezone || 'America/New_York';
    const hhmm = time.substring(0, 5);
    const start = parseInt(hhmm.split(':')[0]) * 60 + parseInt(hhmm.split(':')[1]);
    const end = start + 60;
    const endTime = `${String(Math.floor(end / 60)).padStart(2, '0')}:${String(end % 60).padStart(2, '0')}`;
    const patch = {
      start: { dateTime: `${date}T${hhmm}:00`, timeZone },
      end: { dateTime: `${date}T${endTime}:00`, timeZone }
    };
    if (title) patch.summary = title;
    await gcalRequest(auth.orgId, 'PATCH', `/calendars/primary/events/${encodeURIComponent(eventId)}`, patch);
    return { statusCode: 200, headers, body: JSON.stringify({ success: true }) };
  } catch (err) {
    console.error('GCal update event error:', err);
    return { statusCode: 200, headers, body: JSON.stringify({ success: false, error: err.message }) };
  }
};
