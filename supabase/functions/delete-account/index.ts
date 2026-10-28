// Deletes the CALLER's own account. Trusted backend half of F7B.
//
// Flow (the database step and the Auth step are separate services, so this is
// a recoverable state machine, not one transaction):
//   1. Validate the caller's JWT with the Auth server (never trust the body).
//   2. begin_account_deletion(user.id) runs with the service-role client (the
//      function is service_role only): atomic database cleanup, marks the
//      profile `deleting`. Safe to repeat.
//   3. The Auth user is deleted with the service-role client.
//   4. finalize_account_deletion() marks the profile `deleted`; it refuses
//      unless the Auth user is really gone.
// If step 3 or 4 fails the profile stays `deleting` and the app simply calls
// this function again. The service-role key never leaves this function.
//
// A JWT stays technically valid after the Auth user is deleted, so the
// database independently refuses a deleting / deleted account.
//
// Email-linked accounts (F1b) must also prove control of their CONFIRMED email
// with a fresh code, verified HERE against Supabase Auth on a separate,
// non-persistent client. The email and the user id come from the caller's own
// getUser() answer, never from the request body; the verification must return
// that same user id. The session Auth issues for that verification is
// discarded (and revoked) and never reaches the caller.
//
// KNOWN AUTH LIMITATION: Auth can accept one code more than once when
// verifications run at the same time (see tests/delete_account_otp_preflight.sh).
// The code is therefore proof of email control, not an exactly-once lock. That
// is safe here because it can only ever authorize deleting the caller's own
// account, and begin_account_deletion is serialized per user and idempotent, so
// parallel requests converge on one deletion.
//
// Each verification attempt is also limited per user in the database
// (reserve_deletion_code_attempt, migration 20261109000001); that limit does
// not revoke a code Auth already issued and does not fix the concurrent
// acceptance above.
//
// An account that is already `deleting` was authorized earlier (only this
// function, after the checks above, can put a profile there) and may resume
// without a new code. An active linked account never can.
import {
  createClient,
  type SupabaseClient,
  type User,
} from 'jsr:@supabase/supabase-js@2';

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

const CONFIRMATION_PHRASE = 'DELETE';
const CODE_PATTERN = /^[0-9]{6}$/; // local Auth otp_length = 6

function json(
  status: number,
  body: Record<string, unknown>,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
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

  let body: { confirmation?: unknown; code?: unknown } = {};
  try {
    body = await request.json();
  } catch (_) {
    return json(400, { error: 'invalid_body' });
  }
  if (body.confirmation !== CONFIRMATION_PHRASE) {
    return json(400, { error: 'confirmation_required' });
  }

  // Privileged client: service-role key only, never the caller's Authorization.
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Email-linked accounts must re-verify their email (F1b). The decision uses
  // only the Auth answer above and server-side data, never the request body.
  if (!user.is_anonymous) {
    const code = typeof body.code === 'string' ? body.code.trim() : '';
    const refusal = await requireReverification(admin, user, code);
    if (refusal) return refusal;
  }

  // 2. Database cleanup. Only service_role may call it; the target is the
  // verified Auth user, never a value from the request body.
  const { error: beginError } = await admin.rpc('begin_account_deletion', {
    p_user_id: user.id,
  });
  if (beginError) {
    if (beginError.code === 'AD002') {
      return json(409, { error: 'owns_households' });
    }
    console.error('begin_account_deletion failed', beginError.code);
    return json(500, { error: 'cleanup_failed', state: 'unknown' });
  }

  // 3. Auth deletion with the privileged client; only ever the caller's id.
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

// Returns a refusal, or null when this linked account may proceed to deletion.
async function requireReverification(
  admin: SupabaseClient,
  user: User,
  code: string,
): Promise<Response | null> {
  const email = user.email ?? '';
  if (!email || !user.email_confirmed_at) {
    return json(403, { error: 'reverification_unavailable' });
  }

  // Trusted server data: the profile of the verified caller.
  const { data: profile, error: profileError } = await admin
    .from('profiles')
    .select('account_state')
    .eq('user_id', user.id)
    .maybeSingle();
  if (profileError) {
    console.error('profile state read failed', profileError.code);
    return json(500, { error: 'state_unavailable' });
  }
  // Already prepared by an earlier, verified request: finish it.
  if (profile?.account_state === 'deleting') return null;

  // Optimization only: do not spend a code on a request that must fail with
  // 409. begin_account_deletion stays the authoritative owner check.
  const { count, error: ownerError } = await admin
    .from('household_members')
    .select('household_id', { count: 'exact', head: true })
    .eq('user_id', user.id)
    .eq('role', 'owner')
    .eq('status', 'active');
  if (ownerError) {
    console.error('owner pre-check failed', ownerError.code);
    return json(500, { error: 'cleanup_failed', state: 'unknown' });
  }
  if ((count ?? 0) > 0) return json(409, { error: 'owns_households' });

  if (code === '') return json(403, { error: 'reverification_required' });
  // A malformed code never reaches Auth, so it does not use an attempt.
  if (!CODE_PATTERN.test(code)) {
    return json(403, { error: 'verification_failed' });
  }

  // Reserve an attempt for THIS user BEFORE asking Auth, atomically in the
  // database (5 per 15 minutes, every submission counts). Checking first and
  // counting afterwards would let parallel requests slip past the limit. Auth's
  // own limit is per source IP, which here is this function for every user.
  // Any problem with the limiter fails closed: Auth is not contacted.
  const reservation = await reserveCodeAttempt(admin, user.id);
  if (reservation === null) {
    return json(502, { error: 'verification_unavailable' });
  }
  if (!reservation.allowed) {
    return json(
      429,
      { error: 'too_many_attempts' },
      { 'Retry-After': String(reservation.retryAfterSeconds) },
    );
  }
  return await verifyEmailCode(admin, user, email, code);
}

// Null means the limiter could not give a trustworthy answer.
async function reserveCodeAttempt(
  admin: SupabaseClient,
  userId: string,
): Promise<{ allowed: boolean; retryAfterSeconds: number } | null> {
  const { data, error } = await admin.rpc('reserve_deletion_code_attempt', {
    p_user_id: userId,
  });
  if (error) {
    console.error('attempt reservation failed', error.code);
    return null;
  }
  const row = Array.isArray(data) ? data[0] : data;
  if (!row || typeof row.allowed !== 'boolean') {
    console.error('attempt reservation gave an unexpected answer');
    return null;
  }
  return {
    allowed: row.allowed,
    retryAfterSeconds: Math.max(1, Number(row.retry_after_seconds) || 1),
  };
}

async function verifyEmailCode(
  admin: SupabaseClient,
  user: User,
  email: string,
  code: string,
): Promise<Response | null> {
  // Separate, non-persistent client: it cannot touch the caller's session.
  const verifier = createClient(supabaseUrl, anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
  try {
    const { data, error } = await verifier.auth.verifyOtp({
      email,
      token: code,
      type: 'email',
    });
    if (error) {
      const status = error.status ?? 0;
      const errorCode = (error as { code?: string }).code ?? '';
      console.error('code verification failed', status, errorCode);
      if (status === 429 || errorCode.startsWith('over_')) {
        return json(429, { error: 'rate_limited' });
      }
      if (
        status === 0 || status >= 500 || error.name === 'AuthRetryableFetchError'
      ) {
        return json(502, { error: 'verification_unavailable' });
      }
      return json(403, { error: 'verification_failed' });
    }
    // Whatever session this created is not ours to keep: revoke it and never
    // hand it out.
    const accessToken = data.session?.access_token;
    if (accessToken) {
      try {
        await admin.auth.admin.signOut(accessToken, 'local');
      } catch (_) {
        // The session dies with the user; nothing else to do.
      }
    }
    if (data.user?.id !== user.id) {
      console.error('code verification returned a different user');
      return json(403, { error: 'verification_failed' });
    }
    return null;
  } catch (_) {
    console.error('code verification threw');
    return json(502, { error: 'verification_unavailable' });
  }
}
