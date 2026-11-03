// Delivers queued push notifications. Trusted backend only.
//
// Caller: JWT verification stays ON, so the platform gateway needs a valid
// project JWT (the public anon JWT is enough). That alone authorizes nothing:
// the request must also carry the dedicated secret PUSH_WORKER_INVOKE_SECRET in
// the X-Worker-Secret header. The service-role key is used only inside this
// function for database access and is never an invocation credential.
//
// Delivery semantics are AT LEAST ONCE. Rows are claimed atomically (a row is
// handed to one worker at a time, with a lease), retried a bounded number of
// times, and recorded as processed or failed. A crash after the push provider
// accepted a message but before it was recorded can send it again; the
// provider offers no end-to-end exactly-once mechanism to prevent that.
//
// Privacy: the visible text is always generic. Names, task titles and other
// household text stay in the database and are read by the app, under the
// signed-in user, after the notification is opened. The data fields carry only
// routing ids, which are never treated as authorization.

type OutboxRow = {
  id: string;
  recipient_user_id: string;
  household_id: string | null;
  type: string;
  payload: Record<string, unknown> | null;
};

type DeviceToken = {
  id: string;
  token: string;
  platform: 'android' | 'ios';
};

type SendResult = 'sent' | 'invalid' | 'retry' | 'permanent';

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const invokeSecret = Deno.env.get('PUSH_WORKER_INVOKE_SECRET') ?? '';

// A shorter configured secret is treated as not configured (fail closed).
const MIN_INVOKE_SECRET_LENGTH = 32;
const MAX_ATTEMPTS = 5;
const LEASE = '5 minutes';
const VISIBLE_TITLE = 'Household OS';
const VISIBLE_BODY = 'You have a new update';
const ROUTING_KEYS = ['type', 'householdId', 'taskId'] as const;
const ID_PATTERN = /^[0-9a-fA-F-]{36}$/;
const TYPE_PATTERN = /^[a-z_]{1,40}$/;

// Registrations not refreshed for this many days are skipped and removed. 0
// (the default) disables it: deployed app versions only refresh a registration
// when the user changes the setting, so enable this only once the app version
// that re-registers at every launch is the minimum supported version.
const tokenMaxAgeDays = Number(Deno.env.get('PUSH_TOKEN_MAX_AGE_DAYS') ?? '0');

// Provider endpoints can be redirected to a local mock ONLY in test mode, so a
// stray variable can never reroute real traffic.
const testMode = Deno.env.get('PUSH_PROVIDER_TEST_MODE') === 'true';
const fcmBase = testMode
  ? (Deno.env.get('FCM_API_BASE') ?? 'https://fcm.googleapis.com')
  : 'https://fcm.googleapis.com';
const googleTokenUrl = testMode
  ? (Deno.env.get('GOOGLE_TOKEN_URL') ?? 'https://oauth2.googleapis.com/token')
  : 'https://oauth2.googleapis.com/token';
const apnsBaseOverride = testMode ? Deno.env.get('APNS_BASE_URL') : undefined;

Deno.serve(async (request) => {
  if (request.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }
  if (!supabaseUrl || !serviceRoleKey || invokeSecret.length < MIN_INVOKE_SECRET_LENGTH) {
    return json({ error: 'Supabase environment is not configured' }, 500);
  }
  // Before any body read or database call: a refused request touches nothing.
  if (!isTrustedCaller(request)) {
    return json({ error: 'unauthorized' }, 401);
  }

  const body = await safeJson(request);
  const limit = Math.max(1, Math.min(Number(body?.limit ?? 10) || 10, 25));
  const rows = await claimRows(limit);
  const summary = { claimed: rows.length, processed: 0, retried: 0, failed: 0 };

  for (const row of rows) {
    try {
      const outcome = await deliver(row);
      if (outcome === 'done') {
        await rpc('complete_notification', { p_id: row.id });
        summary.processed++;
      } else if (outcome === 'permanent') {
        await rpc('fail_notification', { p_id: row.id, p_permanent: true });
        summary.failed++;
      } else {
        await rpc('fail_notification', { p_id: row.id, p_max_attempts: MAX_ATTEMPTS });
        summary.retried++;
      }
    } catch (error) {
      // One recipient's problem must not affect other rows; retry later. Only
      // the error text is logged: never a token, key or notification content.
      console.error(`delivery failed for ${row.id}: ${safeErrorText(error)}`);
      await rpc('fail_notification', { p_id: row.id, p_max_attempts: MAX_ATTEMPTS }).catch(
        () => {},
      );
      summary.retried++;
    }
  }

  const pruned = await housekeeping();
  console.log(JSON.stringify({ ...summary, ...pruned }));
  return json({ ...summary, ...pruned });
});

// Error text for the log. A network error can quote the request URL, and an
// APNs URL contains the device token, so anything token-like is redacted.
function safeErrorText(error: unknown): string {
  return String(error)
    .replace(/[A-Za-z0-9:_.=+\/%-]{32,}/g, '[redacted]')
    .slice(0, 200);
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

function isTrustedCaller(request: Request): boolean {
  const presented = request.headers.get('x-worker-secret') ?? '';
  if (presented === '') return false;
  return constantTimeEqual(presented, invokeSecret);
}

function constantTimeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  let diff = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i++) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}

// ---------------------------------------------------------------------------
// Database access (service role, PostgREST)
// ---------------------------------------------------------------------------

async function safeJson(request: Request): Promise<Record<string, unknown> | null> {
  try {
    return await request.json();
  } catch (_) {
    return null;
  }
}

function supabaseFetch(url: URL, init: RequestInit): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set('apikey', serviceRoleKey);
  headers.set('authorization', `Bearer ${serviceRoleKey}`);
  headers.set('content-type', 'application/json');
  return fetch(url, { ...init, headers });
}

async function rpc(name: string, params: Record<string, unknown>): Promise<unknown> {
  const response = await supabaseFetch(new URL(`/rest/v1/rpc/${name}`, supabaseUrl), {
    method: 'POST',
    body: JSON.stringify(params),
  });
  if (!response.ok) throw new Error(`rpc ${name} failed (${response.status})`);
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

async function claimRows(limit: number): Promise<OutboxRow[]> {
  const rows = await rpc('claim_notification_outbox', {
    p_limit: limit,
    p_lease: LEASE,
    p_max_attempts: MAX_ATTEMPTS,
  });
  return (rows as OutboxRow[]) ?? [];
}

function cutoffIso(): string | null {
  if (!(tokenMaxAgeDays > 0)) return null;
  return new Date(Date.now() - tokenMaxAgeDays * 86_400_000).toISOString();
}

async function fetchDeviceTokens(userId: string): Promise<DeviceToken[]> {
  const url = new URL('/rest/v1/device_push_tokens', supabaseUrl);
  url.searchParams.set('select', 'id,token,platform');
  url.searchParams.set('user_id', `eq.${userId}`);
  const cutoff = cutoffIso();
  if (cutoff) url.searchParams.set('updated_at', `gte.${cutoff}`);
  const response = await supabaseFetch(url, { method: 'GET' });
  if (!response.ok) throw new Error('Failed to fetch device tokens');
  return await response.json();
}

// Deletes exactly this registration: one id, never a user's other devices.
async function deleteDeviceToken(id: string): Promise<void> {
  const url = new URL('/rest/v1/device_push_tokens', supabaseUrl);
  url.searchParams.set('id', `eq.${id}`);
  await supabaseFetch(url, { method: 'DELETE' });
}

async function housekeeping(): Promise<{ prunedOutbox: number; prunedTokens: number }> {
  let prunedOutbox = 0;
  let prunedTokens = 0;
  try {
    prunedOutbox = Number(await rpc('prune_notification_outbox', {})) || 0;
  } catch (_) { /* retried on the next run */ }
  const cutoff = cutoffIso();
  if (cutoff) {
    try {
      const url = new URL('/rest/v1/device_push_tokens', supabaseUrl);
      url.searchParams.set('updated_at', `lt.${cutoff}`);
      url.searchParams.set('select', 'id');
      const response = await supabaseFetch(url, {
        method: 'DELETE',
        headers: { prefer: 'return=representation' },
      });
      if (response.ok) prunedTokens = ((await response.json()) as unknown[]).length;
    } catch (_) { /* retried on the next run */ }
  }
  return { prunedOutbox, prunedTokens };
}

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

async function deliver(row: OutboxRow): Promise<'done' | 'retry' | 'permanent'> {
  const tokens = await fetchDeviceTokens(row.recipient_user_id);
  if (tokens.length === 0) return 'done'; // nothing to deliver to

  const data = routingData(row);
  let sent = 0;
  let retry = false;
  let permanent = false;
  for (const token of tokens) {
    const result = token.platform === 'android'
      ? await sendFcm(token, data)
      : await sendApns(token, data);
    if (result === 'sent') sent++;
    if (result === 'invalid') await deleteDeviceToken(token.id);
    if (result === 'retry') retry = true;
    if (result === 'permanent') permanent = true;
  }
  // Retried only while no device has it: once one device received the
  // notification, repeating it for the others would spam the healthy device.
  if (sent === 0 && retry) return 'retry';
  if (sent === 0 && permanent) return 'permanent';
  return 'done';
}

// Only the ids the app needs to open the right screen; anything else in the
// stored payload (or a malformed value) is dropped.
function routingData(row: OutboxRow): Record<string, string> {
  const source: Record<string, unknown> = { ...(row.payload ?? {}) };
  const data: Record<string, string> = {};
  for (const key of ROUTING_KEYS) {
    const value = source[key];
    if (typeof value !== 'string') continue;
    const valid = key === 'type' ? TYPE_PATTERN.test(value) : ID_PATTERN.test(value);
    if (valid) data[key] = value;
  }
  return data;
}

async function readJson(response: Response): Promise<Record<string, unknown>> {
  try {
    return await response.json();
  } catch (_) {
    return {};
  }
}

async function sendFcm(token: DeviceToken, data: Record<string, string>): Promise<SendResult> {
  const projectId = Deno.env.get('FCM_PROJECT_ID');
  const clientEmail = Deno.env.get('FCM_CLIENT_EMAIL');
  const privateKey = Deno.env.get('FCM_PRIVATE_KEY')?.replaceAll('\\n', '\n');
  if (!projectId || !clientEmail || !privateKey) return 'retry';

  const accessToken = await googleAccessToken(clientEmail, privateKey);
  const response = await fetch(`${fcmBase}/v1/projects/${projectId}/messages:send`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      message: {
        token: token.token,
        notification: { title: VISIBLE_TITLE, body: VISIBLE_BODY },
        data,
      },
    }),
  });
  if (response.ok) return 'sent';
  return classifyFcmError(response.status, await readJson(response));
}

// A token is removed only when FCM says the token itself is bad. A 400 that is
// about the message (payload, configuration) never deletes a valid token.
export function classifyFcmError(status: number, body: Record<string, unknown>): SendResult {
  const error = (body.error ?? {}) as {
    status?: string;
    details?: Array<{ errorCode?: string; fieldViolations?: Array<{ field?: string }> }>;
  };
  const details = error.details ?? [];
  if (details.some((d) => d.errorCode === 'UNREGISTERED')) return 'invalid';
  if (status === 404 && error.status === 'NOT_FOUND') return 'invalid';
  if (status === 400) {
    const aboutToken = details.some((d) =>
      (d.fieldViolations ?? []).some((v) => (v.field ?? '').includes('token'))
    );
    return aboutToken ? 'invalid' : 'permanent';
  }
  if (status === 401 || status === 403 || status === 429 || status >= 500) return 'retry';
  return 'permanent';
}

async function sendApns(token: DeviceToken, data: Record<string, string>): Promise<SendResult> {
  const teamId = Deno.env.get('APNS_TEAM_ID');
  const keyId = Deno.env.get('APNS_KEY_ID');
  const bundleId = Deno.env.get('APNS_BUNDLE_ID');
  const privateKey = Deno.env.get('APNS_PRIVATE_KEY')?.replaceAll('\\n', '\n');
  if (!teamId || !keyId || !bundleId || !privateKey) return 'retry';

  const jwt = await apnsJwt(teamId, keyId, privateKey);
  const base = apnsBaseOverride ?? (
    Deno.env.get('APNS_PRODUCTION') === 'true'
      ? 'https://api.push.apple.com'
      : 'https://api.sandbox.push.apple.com'
  );
  const response = await fetch(`${base}/3/device/${token.token}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${jwt}`,
      'apns-topic': bundleId,
      'apns-push-type': 'alert',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      aps: { alert: { title: VISIBLE_TITLE, body: VISIBLE_BODY }, sound: 'default' },
      payload: data,
    }),
  });
  if (response.ok) return 'sent';
  return classifyApnsError(response.status, await readJson(response));
}

export function classifyApnsError(status: number, body: Record<string, unknown>): SendResult {
  const reason = String(body.reason ?? '');
  if (status === 410) return 'invalid';
  if (status === 400) {
    return reason === 'BadDeviceToken' || reason === 'DeviceTokenNotForTopic'
      ? 'invalid'
      : 'permanent';
  }
  if (status === 403 || status === 429 || status >= 500) return 'retry';
  return 'permanent';
}

// ---------------------------------------------------------------------------
// Provider authentication helpers
// ---------------------------------------------------------------------------

async function googleAccessToken(clientEmail: string, privateKeyPem: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const jwt = await signJwt(
    { alg: 'RS256', typ: 'JWT' },
    {
      iss: clientEmail,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    },
    privateKeyPem,
    'RSASSA-PKCS1-v1_5',
    'SHA-256',
  );
  const response = await fetch(googleTokenUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  if (!response.ok) throw new Error('Failed to fetch FCM access token');
  const jsonBody = await response.json();
  return jsonBody.access_token;
}

async function apnsJwt(teamId: string, keyId: string, privateKeyPem: string): Promise<string> {
  return signJwt(
    { alg: 'ES256', kid: keyId },
    { iss: teamId, iat: Math.floor(Date.now() / 1000) },
    privateKeyPem,
    'ECDSA',
    'SHA-256',
  );
}

async function signJwt(
  header: Record<string, unknown>,
  payload: Record<string, unknown>,
  privateKeyPem: string,
  algorithmName: 'RSASSA-PKCS1-v1_5' | 'ECDSA',
  hash: 'SHA-256',
): Promise<string> {
  const encodedHeader = base64UrlEncode(new TextEncoder().encode(JSON.stringify(header)));
  const encodedPayload = base64UrlEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const data = new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`);
  // An EC key must name its curve when imported (APNs uses P-256); without it
  // the import throws and no iOS notification can ever be sent.
  const importAlgorithm = algorithmName === 'ECDSA'
    ? { name: 'ECDSA', namedCurve: 'P-256' }
    : { name: algorithmName, hash };
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToArrayBuffer(privateKeyPem),
    importAlgorithm,
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign({ name: algorithmName, hash }, key, data);
  return `${encodedHeader}.${encodedPayload}.${base64UrlEncode(new Uint8Array(signature))}`;
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s/g, '');
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}
