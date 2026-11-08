const { createClient } = require('@supabase/supabase-js');
const { getOrgBySlug, getOrgSetting } = require('./utils');

// Convert old-format type config to new schedule format, resolving global defaults
function normalizeTypeConfig(typeConfig, globalDefaults) {
  const g = globalDefaults || {};
  const slot_duration = typeConfig.slot_duration || 60;
  const buffer_minutes = typeConfig.buffer_minutes || 15;
  const lead_time_hours = (typeConfig.lead_time_hours != null ? typeConfig.lead_time_hours : null) ?? g.lead_time_hours ?? 24;
  const max_advance_days = (typeConfig.max_advance_days != null ? typeConfig.max_advance_days : null) ?? g.max_advance_days ?? 60;

  let schedule;
  if (typeConfig.schedule) {
    schedule = typeConfig.schedule;
  } else if (typeConfig.days) {
    // Old format: days array + single start/end
    const start = typeConfig.start_time || '09:00';
    const end = typeConfig.end_time || '17:00';
    schedule = {};
    for (let d = 1; d <= 7; d++) {
      schedule[String(d)] = typeConfig.days.includes(d) ? [{ start, end }] : [];
    }
  } else {
    // Default: Mon-Fri 9-5
    schedule = {};
    for (let d = 1; d <= 7; d++) {
      schedule[String(d)] = d <= 5 ? [{ start: '09:00', end: '17:00' }] : [];
    }
  }

  return { slot_duration, buffer_minutes, lead_time_hours, max_advance_days, schedule };
}

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
    'Content-Type': 'application/json'
  };

  // Handle CORS preflight
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers, body: '' };
  }

  try {
    // Check environment variables
    if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
      console.error('Missing environment variables');
      return {
        statusCode: 500,
        headers,
        body: JSON.stringify({
          error: 'Server configuration error',
          details: 'Missing database credentials'
        })
      };
    }

    const supabase = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY
    );

    const typeId = event.queryStringParameters?.type_id;
    const month = event.queryStringParameters?.month;
    const orgSlug = event.queryStringParameters?.org;

    // Which business? From the appointment type, or from /schedule/<slug>
    let orgId = null;
    if (typeId) {
      const { data: t } = await supabase.from('appointment_types').select('org_id').eq('id', typeId).maybeSingle();
      orgId = t?.org_id || null;
    } else {
      const org = await getOrgBySlug(supabase, orgSlug);
      orgId = org?.id || null;
    }
    if (!orgId) {
      return { statusCode: 404, headers, body: JSON.stringify({ error: 'Booking page not found' }) };
    }

    const scheduling = await getOrgSetting(supabase, orgId, 'scheduling');
    const company = await getOrgSetting(supabase, orgId, 'company');

    // Load all active appointment types
    const { data: appointmentTypes, error: typesError } = await supabase
      .from('appointment_types')
      .select('*')
      .eq('org_id', orgId)
      .eq('is_active', true)
      .order('sort_order');

    if (typesError) {
      console.error('Appointment types query error:', typesError);
      return {
        statusCode: 500,
        headers,
        body: JSON.stringify({
          error: 'Failed to load appointment types',
          details: typesError.message
        })
      };
    }

    // Get branding settings (logo_url)
    const branding = await getOrgSetting(supabase, orgId, 'branding');
    const logo_url = branding.logo_url || null;

    // -------------------------------------------------------
    // GET without type_id: return list of enabled types
    // -------------------------------------------------------
    if (!typeId) {
      // Before the business saves any scheduling settings, every active type is bookable
      // with default hours (Mon–Fri 9–5). After that, only types switched on in Settings.
      const configured = scheduling.types && Object.keys(scheduling.types).length > 0;
      const enabledTypes = (appointmentTypes || [])
        .filter(t => !configured || (scheduling.types[t.id] && scheduling.types[t.id].enabled === true))
        .map(t => ({
          id: t.id,
          name: t.name,
          icon: t.icon,
          color: t.color
        }));

      return {
        statusCode: 200,
        headers,
        body: JSON.stringify({ types: enabledTypes, logo_url, business_name: company.name || '', brand_color: branding.color || null, phone: company.phone || '' })
      };
    }

    // -------------------------------------------------------
    // GET with type_id (and month): return availability data
    // -------------------------------------------------------
    const appointmentType = (appointmentTypes || []).find(t => t.id === typeId);

    if (!appointmentType) {
      return {
        statusCode: 404,
        headers,
        body: JSON.stringify({ error: 'Appointment type not found' })
      };
    }

    const typeConfig = (scheduling.types && scheduling.types[typeId]) || {};
    const config = normalizeTypeConfig(typeConfig, scheduling.global);

    // Determine month range
    const targetMonth = month || new Date().toISOString().slice(0, 7); // fallback to current month
    const [year, mon] = targetMonth.split('-').map(Number);
    const firstOfMonth = `${targetMonth}-01`;
    const lastDay = new Date(year, mon, 0).getDate();
    const lastOfMonth = `${targetMonth}-${String(lastDay).padStart(2, '0')}`;

    // Blocked dates from scheduling config (filtered to this month)
    const blockedDates = (scheduling.blocked_dates || []).filter(d => d >= firstOfMonth && d <= lastOfMonth);

    // Blocked time ranges from scheduling config (filtered to this month)
    const blockedTimes = (scheduling.blocked_times || []).filter(bt => bt.date >= firstOfMonth && bt.date <= lastOfMonth);

    // Load ALL appointments in the month (any type — single operator)
    const { data: appointments, error: apptsError } = await supabase
      .from('appointments')
      .select('appointment_date, appointment_time, appointment_type_id')
      .eq('org_id', orgId)
      .gte('appointment_date', firstOfMonth)
      .lte('appointment_date', lastOfMonth)
      .neq('status', 'cancelled');

    if (apptsError) {
      console.error('Appointments query error:', apptsError);
    }

    const bookedSlots = (appointments || []).map(appt => {
      const apptTypeConfig = (scheduling.types && scheduling.types[appt.appointment_type_id]) || {};
      const duration = apptTypeConfig.slot_duration || 60;
      return {
        date: appt.appointment_date,
        time: appt.appointment_time,
        duration,
        type_id: appt.appointment_type_id
      };
    });

    // Count appointments per day for the requested type (for max_per_day limit)
    const maxPerDay = typeConfig.max_per_day || 0;
    let typeCountByDate = {};
    if (maxPerDay > 0) {
      typeCountByDate = {};
      (appointments || []).forEach(appt => {
        if (appt.appointment_type_id === typeId) {
          typeCountByDate[appt.appointment_date] = (typeCountByDate[appt.appointment_date] || 0) + 1;
        }
      });
    }

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        type: {
          id: appointmentType.id,
          name: appointmentType.name,
          icon: appointmentType.icon,
          color: appointmentType.color
        },
        config,
        max_per_day: maxPerDay,
        type_count_by_date: typeCountByDate,
        blocked_dates: blockedDates,
        blocked_times: blockedTimes,
        booked_slots: bookedSlots
      })
    };

  } catch (err) {
    console.error('Schedule availability error:', err);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({
        error: 'Server error',
        message: err.message
      })
    };
  }
};
