// =============================================
// SETUP STATUS (public)
//  GET → { configured: boolean }
//  Single-business app: "configured" means the one business has been created.
//  The sign-up page uses this to turn into a sign-in page after first setup.
// =============================================

const { getSupabase, success, error, handleCors } = require('./utils');

exports.handler = async (event) => {
  const cors = handleCors(event);
  if (cors) return cors;
  if (event.httpMethod !== 'GET') return error('Method not allowed', 405);
  try {
    const admin = getSupabase();
    const { count, error: err } = await admin
      .from('organizations')
      .select('id', { count: 'exact', head: true });
    if (err) throw err;
    return success({ configured: (count || 0) > 0 });
  } catch (err) {
    console.error('[setup-status] error:', err);
    return error('Could not check setup status', 500);
  }
};
