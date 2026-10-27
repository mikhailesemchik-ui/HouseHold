// Deletes the CALLER's own account. Trusted backend half of F7B.
//
// Flow (the database step and the Auth step are separate services, so this is
// a recoverable state machine, not one transaction):
//   1. Validate the caller's JWT with the Auth server (never trust the body).
//   2. begin_account_deletion() runs as the caller: atomic database cleanup,
//      marks the profile `deleting`. Safe to repeat.
//   3. The Auth user is deleted with the service-role client.
//   4. finalize_account_deletion() marks the profile `deleted`; it refuses
//      unless the Auth user is really gone.
// If step 3 or 4 fails the profile stays `deleting` and the app simply calls
// this function again. The service-role key never leaves this function.
//
// A JWT stays technically valid after the Auth user is deleted, so the
// database independently refuses a deleting / deleted account.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

const CONFIRMATION_PHRASE = 'DELETE';

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json(405, { error: 'method_not_allowed' });
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json(500, { error: 'server_not_configured' });
  }

  const authorization = request.headers.get('Authorization') ?? '';
  if (!authorization.toLowerCase().startsWith('bearer ')) {
    return json(401, { error: 'unauthorized' });
  }

  // 1. The caller, as verified by the Auth server.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  const user = userData?.user;
  if (userError || !user) return json(401, { error: 'unauthorized' });

  let body: { confirmation?: unknown } = {};
  try {
    body = await request.json();
  } catch (_) {
    return json(400, { error: 'invalid_body' });
  }
  if (body.confirmation !== CONFIRMATION_PHRASE) {
    return json(400, { error: 'confirmation_required' });
  }

  // Email-linked accounts (F1) must re-verify before deletion. Until that
  // flow exists, refuse them instead of trusting a stale session.
  if (!user.is_anonymous) {
    return json(403, { error: 'reverification_required' });
  }

  // 2. Database cleanup as the caller (auth.uid() is the only identity used).
  const { error: beginError } = await userClient.rpc('begin_account_deletion');
  if (beginError) {
    if (beginError.code === 'AD002') {
      return json(409, { error: 'owns_households' });
    }
    console.error('begin_account_deletion failed', beginError.code);
    return json(500, { error: 'cleanup_failed', state: 'unknown' });
  }

  // 3. Auth deletion with the privileged client; only ever the caller's id.
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  const alreadyGone = deleteError?.status === 404 ||
    deleteError?.code === 'user_not_found';
  if (deleteError && !alreadyGone) {
    console.error('auth deleteUser failed', deleteError.status);
    return json(502, { error: 'auth_delete_failed', state: 'deleting' });
  }

  // 4. Only now is the account marked deleted.
  const { error: finalizeError } = await admin.rpc('finalize_account_deletion', {
    p_user_id: user.id,
  });
  if (finalizeError) {
    console.error('finalize_account_deletion failed', finalizeError.code);
    return json(502, { error: 'finalize_failed', state: 'deleting' });
  }
  return json(200, { state: 'deleted' });
});
