type OutboxRow = {
  id: string;
  recipient_user_id: string;
  household_id: string | null;
  type: string;
  title: string;
  body: string;
  payload: Record<string, unknown>;
};

type DeviceToken = {
  id: string;
  token: string;
  platform: 'android' | 'ios';
};

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

Deno.serve(async (request) => {
  if (request.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ error: 'Supabase environment is not configured' }, 500);
  }

  const body = await safeJson(request);
  const limit = Math.min(Number(body?.limit ?? 10), 25);
  const rows = await fetchOutboxRows(limit);
  let processed = 0;

  for (const row of rows) {
    const tokens = await fetchDeviceTokens(row.recipient_user_id);
    if (tokens.length === 0) {
      await markProcessed(row.id);
      processed++;
      continue;
    }

    const result = await sendToTokens(row, tokens);
    for (const tokenId of result.invalidTokenIds) {
      await deleteDeviceToken(tokenId);
    }
    if (result.ok) {
      await markProcessed(row.id);
      processed++;
    }
  }

  return json({ fetched: rows.length, processed });
});

async function safeJson(request: Request): Promise<Record<string, unknown> | null> {
  try {
    return await request.json();
  } catch (_) {
    return null;
  }
}

async function fetchOutboxRows(limit: number): Promise<OutboxRow[]> {
  const url = new URL('/rest/v1/notification_outbox', supabaseUrl);
  url.searchParams.set('select', 'id,recipient_user_id,household_id,type,title,body,payload');
  url.searchParams.set('processed_at', 'is.null');
  url.searchParams.set('order', 'created_at.asc');
  url.searchParams.set('limit', String(limit));
  const response = await supabaseFetch(url, { method: 'GET' });
  if (!response.ok) throw new Error('Failed to fetch notification outbox');
  return await response.json();
}

async function fetchDeviceTokens(userId: string): Promise<DeviceToken[]> {
  const url = new URL('/rest/v1/device_push_tokens', supabaseUrl);
  url.searchParams.set('select', 'id,token,platform');
  url.searchParams.set('user_id', `eq.${userId}`);
  const response = await supabaseFetch(url, { method: 'GET' });
  if (!response.ok) throw new Error('Failed to fetch device tokens');
  return await response.json();
}

async function markProcessed(id: string): Promise<void> {
  const url = new URL('/rest/v1/notification_outbox', supabaseUrl);
  url.searchParams.set('id', `eq.${id}`);
  const response = await supabaseFetch(url, {
    method: 'PATCH',
    body: JSON.stringify({ processed_at: new Date().toISOString() }),
  });
  if (!response.ok) throw new Error('Failed to mark notification processed');
}

async function deleteDeviceToken(id: string): Promise<void> {
  const url = new URL('/rest/v1/device_push_tokens', supabaseUrl);
  url.searchParams.set('id', `eq.${id}`);
  await supabaseFetch(url, { method: 'DELETE' });
}

function supabaseFetch(url: URL, init: RequestInit): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set('apikey', serviceRoleKey);
  headers.set('authorization', `Bearer ${serviceRoleKey}`);
  headers.set('content-type', 'application/json');
  return fetch(url, { ...init, headers });
}

async function sendToTokens(
  row: OutboxRow,
  tokens: DeviceToken[],
): Promise<{ ok: boolean; invalidTokenIds: string[] }> {
  const invalidTokenIds: string[] = [];
  let hadConfigError = false;
  let hadSendError = false;

  for (const token of tokens) {
    const result = token.platform === 'android'
      ? await sendFcm(row, token)
      : await sendApns(row, token);
    if (result === 'invalid') invalidTokenIds.push(token.id);
    if (result === 'config_error') hadConfigError = true;
    if (result === 'send_error') hadSendError = true;
  }

  return { ok: !hadConfigError && !hadSendError, invalidTokenIds };
}

type SendResult = 'sent' | 'invalid' | 'config_error' | 'send_error';

async function sendFcm(row: OutboxRow, token: DeviceToken): Promise<SendResult> {
  const projectId = Deno.env.get('FCM_PROJECT_ID');
  const clientEmail = Deno.env.get('FCM_CLIENT_EMAIL');
  const privateKey = Deno.env.get('FCM_PRIVATE_KEY')?.replaceAll('\\n', '\n');
  if (!projectId || !clientEmail || !privateKey) return 'config_error';

  const accessToken = await googleAccessToken(clientEmail, privateKey);
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: 'POST',
      headers: {
        authorization: `Bearer ${accessToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token: token.token,
          notification: { title: row.title, body: row.body },
          data: stringifyPayload(row.payload),
        },
      }),
    },
  );

  if (response.ok) return 'sent';
  if (response.status === 404 || response.status === 400) return 'invalid';
  return 'send_error';
}

async function sendApns(row: OutboxRow, token: DeviceToken): Promise<SendResult> {
  const teamId = Deno.env.get('APNS_TEAM_ID');
  const keyId = Deno.env.get('APNS_KEY_ID');
  const bundleId = Deno.env.get('APNS_BUNDLE_ID');
  const privateKey = Deno.env.get('APNS_PRIVATE_KEY')?.replaceAll('\\n', '\n');
  if (!teamId || !keyId || !bundleId || !privateKey) return 'config_error';

  const jwt = await apnsJwt(teamId, keyId, privateKey);
  const host = Deno.env.get('APNS_PRODUCTION') === 'true'
    ? 'api.push.apple.com'
    : 'api.sandbox.push.apple.com';
  const response = await fetch(`https://${host}/3/device/${token.token}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${jwt}`,
      'apns-topic': bundleId,
      'apns-push-type': 'alert',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      aps: { alert: { title: row.title, body: row.body }, sound: 'default' },
      payload: row.payload,
    }),
  });

  if (response.ok) return 'sent';
  if (response.status === 400 || response.status === 410) return 'invalid';
  return 'send_error';
}

function stringifyPayload(payload: Record<string, unknown>): Record<string, string> {
  return Object.fromEntries(
    Object.entries(payload).map(([key, value]) => [key, String(value)]),
  );
}

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
  const response = await fetch('https://oauth2.googleapis.com/token', {
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
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToArrayBuffer(privateKeyPem),
    { name: algorithmName, hash },
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
