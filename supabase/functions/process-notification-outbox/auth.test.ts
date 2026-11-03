// Local tests for the worker's invocation authentication. Run with:
//   node --test supabase/functions/process-notification-outbox/auth.test.ts
// (or `deno test`). No network: Deno and fetch are replaced by fakes, and every
// value below is a throwaway placeholder, never a real credential.
import assert from 'node:assert/strict';
import { beforeEach, describe, it } from 'node:test';

type Handler = (request: Request) => Promise<Response>;
type Call = { url: string; headers: Headers };

const SECRET = 'test-invoke-secret-0123456789abcdef-xyz';
const SERVICE_KEY = 'placeholder-service-role-key';
const ANON_JWT = 'placeholder-anon-jwt';

let calls: Call[] = [];
let imports = 0;

async function loadWorker(secret: string | undefined): Promise<Handler> {
  const env: Record<string, string | undefined> = {
    SUPABASE_URL: 'http://localhost.test',
    SUPABASE_SERVICE_ROLE_KEY: SERVICE_KEY,
    PUSH_WORKER_INVOKE_SECRET: secret,
  };
  let handler: Handler | undefined;
  (globalThis as any).Deno = {
    env: { get: (name: string) => env[name] },
    serve: (h: Handler) => {
      handler = h;
    },
  };
  // A fresh module instance per call: the secret is read at load time.
  await import(`./index.ts?instance=${imports++}`);
  assert.ok(handler);
  return handler;
}

function post(headers: Record<string, string>): Request {
  return new Request('http://worker.test/', {
    method: 'POST',
    headers,
    body: '{}',
  });
}

beforeEach(() => {
  calls = [];
  (globalThis as any).fetch = async (url: URL | string, init: RequestInit = {}) => {
    const headers = new Headers(init.headers);
    calls.push({ url: String(url), headers });
    const path = new URL(String(url)).pathname;
    const body = path.endsWith('prune_notification_outbox') ? '0' : '[]';
    return new Response(body, { status: 200 });
  };
});

describe('process-notification-outbox invocation auth', () => {
  it('refuses a request without the worker secret and touches nothing', async () => {
    const handler = await loadWorker(SECRET);
    const response = await handler(post({ authorization: `Bearer ${ANON_JWT}` }));
    assert.equal(response.status, 401);
    assert.equal(calls.length, 0);
  });

  it('refuses the anon JWT alone, even sent as the secret header name only', async () => {
    const handler = await loadWorker(SECRET);
    const response = await handler(post({ authorization: `Bearer ${ANON_JWT}`, 'x-worker-secret': '' }));
    assert.equal(response.status, 401);
    assert.equal(calls.length, 0);
  });

  it('refuses a wrong secret, including a prefix and a longer value', async () => {
    const handler = await loadWorker(SECRET);
    for (const wrong of ['wrong', SECRET.slice(0, -1), `${SECRET}x`, SECRET.toUpperCase()]) {
      const response = await handler(
        post({ authorization: `Bearer ${ANON_JWT}`, 'x-worker-secret': wrong }),
      );
      assert.equal(response.status, 401, wrong);
    }
    assert.equal(calls.length, 0);
  });

  it('refuses the service-role key as an invocation credential', async () => {
    const handler = await loadWorker(SECRET);
    const asBearer = await handler(post({ authorization: `Bearer ${SERVICE_KEY}` }));
    const asSecret = await handler(
      post({ authorization: `Bearer ${ANON_JWT}`, 'x-worker-secret': SERVICE_KEY }),
    );
    assert.equal(asBearer.status, 401);
    assert.equal(asSecret.status, 401);
    assert.equal(calls.length, 0);
  });

  it('fails closed when the configured secret is missing, empty or too short', async () => {
    for (const configured of [undefined, '', 'short-secret']) {
      const handler = await loadWorker(configured);
      // Even presenting the same value (or an empty one) must not get through.
      for (const presented of [configured ?? '', '']) {
        const response = await handler(
          post({ authorization: `Bearer ${ANON_JWT}`, 'x-worker-secret': presented }),
        );
        assert.equal(response.status, 500);
      }
    }
    assert.equal(calls.length, 0);
  });

  it('refuses non-POST requests before any work', async () => {
    const handler = await loadWorker(SECRET);
    const response = await handler(
      new Request('http://worker.test/', {
        method: 'GET',
        headers: { 'x-worker-secret': SECRET },
      }),
    );
    assert.equal(response.status, 405);
    assert.equal(calls.length, 0);
  });

  it('runs the existing worker logic for the valid secret, using the service role internally', async () => {
    const handler = await loadWorker(SECRET);
    const response = await handler(
      post({ authorization: `Bearer ${ANON_JWT}`, 'x-worker-secret': SECRET }),
    );
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.claimed, 0);
    const paths = calls.map((call) => new URL(call.url).pathname);
    assert.deepEqual(paths, [
      '/rest/v1/rpc/claim_notification_outbox',
      '/rest/v1/rpc/prune_notification_outbox',
    ]);
    for (const call of calls) {
      assert.equal(call.headers.get('authorization'), `Bearer ${SERVICE_KEY}`);
      assert.equal(call.headers.get('x-worker-secret'), null);
    }
  });
});
