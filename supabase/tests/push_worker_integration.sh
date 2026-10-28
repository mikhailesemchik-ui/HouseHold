#!/usr/bin/env bash
# Local integration test of the notification worker against a MOCK push provider.
# Never contacts FCM, APNs or Google. Isolated stack only:
#   SB_WORKDIR=<local supabase project dir> DB_CONTAINER=supabase_db_hhsqltest \
#     bash supabase/tests/push_worker_integration.sh
#
# It generates throwaway signing keys in a temp directory (deleted at the end),
# serves the function with PUSH_PROVIDER_TEST_MODE so the provider endpoints
# point at supabase/tests/push_provider_mock.py, creates disposable users,
# tokens and outbox rows, and removes them. Pre-existing pending outbox rows
# are parked (leased into the future) and restored exactly.
# The edge-runtime container it starts is stopped again at the end.
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_hhsqltest}"
case "$DB_CONTAINER" in
  *hhsqltest*) ;;
  *) echo "refusing to run against $DB_CONTAINER" >&2; exit 2 ;;
esac
: "${SB_WORKDIR:?set SB_WORKDIR to the local supabase project directory}"
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PORT="${MOCK_PORT:-18765}"
export MSYS_NO_PATHCONV=1

ENV_DUMP=$(cd "$SB_WORKDIR" && supabase status -o env 2>/dev/null)
ANON=$(echo "$ENV_DUMP" | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')
SERVICE=$(echo "$ENV_DUMP" | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')
API_URL="http://supabase_kong_${DB_CONTAINER#supabase_db_}:8000"
case "$API_URL" in
  http://supabase_kong_*hhsqltest*:8000) ;;
  *) echo "refusing to run against $API_URL" >&2; exit 2 ;;
esac
[ -n "$ANON" ] && [ -n "$SERVICE" ] || { echo "missing local keys" >&2; exit 2; }

psql_() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }
cx() { docker exec -i "$DB_CONTAINER" curl -s "$@"; }
fail() {
  echo "FAIL: $1"
  [ -f "${TMP:-/nonexistent}/serve.log" ] && { echo "--- worker log (tail):"; tail -12 "$TMP/serve.log" | cut -c1-240; }
  exit 1
}
pass() { echo "PASS: $1"; }

TMP=$(mktemp -d)
LOG="$TMP/provider.jsonl"
: > "$LOG"
winpath() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
MOCK_PID=""; SERVE_PID=""
BASE_IDS=""
PROBE_USER_ID=""

# ---- fixtures ---------------------------------------------------------------
U() { printf 'fa000000-0000-0000-0000-0000000000%02d' "$1"; }
HH='fa000000-0000-0000-0000-0000000000aa'
TASK() { printf 'fb000000-0000-0000-0000-0000000000%02d' "$1"; }

stop_worker() {
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true
  SERVE_PID=""
  docker stop "supabase_edge_runtime_${DB_CONTAINER#supabase_db_}" >/dev/null 2>&1 || true
}

cleanup() {
  stop_worker
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
  psql_ <<SQL >/dev/null 2>&1 || true
delete from notification_outbox where recipient_user_id::text like 'fa000000-%';
delete from device_push_tokens where user_id::text like 'fa000000-%';
delete from profiles where user_id::text like 'fa000000-%';
delete from auth.users where id::text like 'fa000000-%';
SQL
  if [ -n "$PROBE_USER_ID" ]; then
    psql_ -c "delete from auth.users where id = '$PROBE_USER_ID'" >/dev/null 2>&1 || true
  fi
  if [ -n "$BASE_IDS" ]; then
    psql_ -c "update notification_outbox set claimed_at = null where id in ($BASE_IDS)" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# Park the pre-existing pending rows so this test cannot touch them.
[ "$(psql_ -c "select count(*) from notification_outbox where claimed_at is not null or attempt_count > 0")" = 0 ] \
  || fail "unexpected pre-existing claimed outbox rows; refusing to continue"
BASE_IDS=$(psql_ -c "select string_agg(quote_literal(id::text), ',') from notification_outbox where processed_at is null and failed_at is null")
if [ -n "$BASE_IDS" ]; then
  psql_ -c "update notification_outbox set claimed_at = now() + interval '6 hours' where id in ($BASE_IDS)" >/dev/null
fi

# ---- throwaway provider keys and the function environment -------------------
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$(winpath "$TMP/fcm.pem")" 2>/dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$(winpath "$TMP/apns.pem")" 2>/dev/null
oneline() { awk 'NF {printf "%s\\n", $0}' "$1"; }
write_env() { # max-age-days
  cat > "$TMP/worker.env" <<ENV
FCM_PROJECT_ID=mock-project
FCM_CLIENT_EMAIL=mock@example.test
FCM_PRIVATE_KEY=$(oneline "$TMP/fcm.pem")
APNS_TEAM_ID=TEAM000000
APNS_KEY_ID=KEY0000000
APNS_BUNDLE_ID=com.example.mock
APNS_PRIVATE_KEY=$(oneline "$TMP/apns.pem")
PUSH_PROVIDER_TEST_MODE=true
FCM_API_BASE=http://host.docker.internal:$PORT
GOOGLE_TOKEN_URL=http://host.docker.internal:$PORT/token
APNS_BASE_URL=http://host.docker.internal:$PORT
PUSH_TOKEN_MAX_AGE_DAYS=$1
ENV
}

python "$(winpath "$HERE/push_provider_mock.py")" "$PORT" "$(winpath "$LOG")" &
MOCK_PID=$!
sleep 1

mkdir -p "$SB_WORKDIR/supabase/functions/process-notification-outbox"
cp "$REPO/supabase/functions/process-notification-outbox/index.ts" \
   "$SB_WORKDIR/supabase/functions/process-notification-outbox/index.ts"

start_worker() { # max-age-days
  stop_worker
  # A restart races with the previous container's removal; clear it explicitly.
  docker rm -f "supabase_edge_runtime_${DB_CONTAINER#supabase_db_}" >/dev/null 2>&1 || true
  sleep 3
  write_env "$1"
  (cd "$SB_WORKDIR" && supabase functions serve process-notification-outbox \
      --env-file "$(winpath "$TMP/worker.env")" > "$TMP/serve.log" 2>&1) &
  SERVE_PID=$!
  local i
  for i in $(seq 1 60); do
    sleep 1
    code=$(cx -o /dev/null -w '%{http_code}' -X POST "$API_URL/functions/v1/process-notification-outbox" \
      -H "Authorization: Bearer $ANON" -d '{}' || true)
    [ "$code" = 401 ] && return 0
  done
  cat "$TMP/serve.log" | tail -5
  fail "the worker did not start"
}

invoke() { # key [limit]
  cx -w '\n%{http_code}' -X POST "$API_URL/functions/v1/process-notification-outbox" \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" -d "{\"limit\":${2:-25}}"
}
status_of() { tail -1; }
body_of() { sed '$d'; }

sends() { python - "$(winpath "$LOG")" "$1" <<'PY'
import json, sys
log, token = sys.argv[1], sys.argv[2]
print(sum(1 for l in open(log, encoding='utf-8') if l.strip() and json.loads(l)['token'] == token))
PY
}
total_sends() { python - "$(winpath "$LOG")" <<'PY'
import sys
print(sum(1 for l in open(sys.argv[1], encoding='utf-8') if l.strip()))
PY
}
sends_with_data() { python - "$(winpath "$LOG")" "$1" <<'PY'
import json, sys
log, task = sys.argv[1], sys.argv[2]
n = 0
for l in open(log, encoding='utf-8'):
    if not l.strip(): continue
    e = json.loads(l); b = e['body']
    data = b['message']['data'] if e['provider'] == 'fcm' else b['payload']
    if data.get('taskId') == task: n += 1
print(n)
PY
}
outbox() { psql_ -c "select $2 from notification_outbox where id = '$1'"; }

mkuser() { # n
  psql_ >/dev/null <<SQL
insert into auth.users (id,email,role,aud,created_at,updated_at,is_anonymous)
 values ('$(U "$1")','pw$1@test.local','authenticated','authenticated',now(),now(),true);
insert into profiles (user_id,public_id,display_name) values ('$(U "$1")','PW-$1','Pw$1');
SQL
}
mktoken() { # user-n token platform [age-days]
  psql_ -c "insert into device_push_tokens (user_id, token, platform, updated_at) values ('$(U "$1")','$2','$3', now() - interval '${4:-0} days')" >/dev/null
}
mkrow() { # user-n task-n -> prints id; secrets sit in title/body/payload on purpose
  psql_ -q -c "insert into notification_outbox (recipient_user_id, household_id, type, title, body, payload)
    values ('$(U "$1")', null, 'task_assigned', 'SECRET-TITLE Alice', 'Alice assigned you \"SECRET-MILK\" in SECRET-HOME',
      jsonb_build_object('type','task_assigned','householdId','$HH','taskId','$(TASK "$2")',
        'taskTitle','SECRET-MILK','inviteCode','SECRET-CODE','memberName','SECRET-ALICE')) returning id"
}

for n in 1 2 3 4 5 6 7 8 9 10 11 12; do mkuser "$n"; done
mktoken 1 tokOKandroid0000000000000000000000000001 android
mktoken 2 tokOKios0000000000000000000000000000002 ios
mktoken 3 tokUNREGandroid00000000000000000000000003 android
mktoken 3 tokOK2android00000000000000000000000004 android
mktoken 4 tokUNREGios00000000000000000000000000005 ios
mktoken 5 tokBADTOKENandroid000000000000000000000006 android
mktoken 6 tokBADPAYLOADandroid0000000000000000000007 android
mktoken 7 tokFLAKYandroid0000000000000000000000008 android
mktoken 8 tokDOWNandroid000000000000000000000000009 android
mktoken 9 tokOK9android000000000000000000000000010 android
mktoken 9 tokDOWN9android0000000000000000000000011 android
mktoken 12 tokOTHERandroid00000000000000000000000012 android

echo "=== the trusted-caller boundary"
start_worker 0
OUT=$(cx -w '\n%{http_code}' -X POST "$API_URL/functions/v1/process-notification-outbox" -d '{}')
[ "$(echo "$OUT" | status_of)" = 401 ] || fail "a request without credentials was not refused"
OUT=$(invoke "$ANON"); [ "$(echo "$OUT" | status_of)" = 401 ] && echo "$OUT" | grep -q unauthorized || fail "the public anon key was accepted"
psql_ -c "select 1" >/dev/null
PROBE=$(cx -X POST "$API_URL/auth/v1/signup" -H "apikey: $ANON" -H "Content-Type: application/json" -d '{}')
USER_JWT=$(echo "$PROBE" | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
PROBE_USER_ID=$(echo "$PROBE" | python -c "import sys,json; print(json.load(sys.stdin)['user']['id'])")
OUT=$(invoke "$USER_JWT"); [ "$(echo "$OUT" | status_of)" = 401 ] || fail "a signed-in user's JWT was accepted"
OUT=$(cx -w '\n%{http_code}' -X GET "$API_URL/functions/v1/process-notification-outbox" -H "Authorization: Bearer $SERVICE")
[ "$(echo "$OUT" | status_of)" = 405 ] || fail "GET was not refused"
[ "$(total_sends)" = 0 ] || fail "a refused call sent notifications"
pass "no credentials, the anon key and a user JWT are refused with no delivery; only the service role is accepted"

R1=$(mkrow 1 1); R2=$(mkrow 2 2); R3=$(mkrow 3 3); R4=$(mkrow 4 4); R5=$(mkrow 5 5)
R6=$(mkrow 6 6); R7=$(mkrow 7 7); R8=$(mkrow 8 8); R9=$(mkrow 9 9); R10=$(mkrow 10 10)

echo "=== run 1: delivery, privacy, invalid tokens, retry classification"
OUT=$(invoke "$SERVICE"); [ "$(echo "$OUT" | status_of)" = 200 ] || fail "the worker did not run: $OUT"
echo "summary: $(echo "$OUT" | body_of)"
[ "$(sends tokOKandroid0000000000000000000000000001)" = 1 ] || fail "user 1 did not receive exactly one notification"
[ "$(sends tokOKios0000000000000000000000000000002)" = 1 ] || fail "user 2 (iOS) did not receive exactly one"
[ "$(sends tokOTHERandroid00000000000000000000000012)" = 0 ] || fail "a user with no outbox row received a notification"
pass "each recipient's device received exactly one notification; an unrelated user's device received none"

python - "$(winpath "$LOG")" <<'PY' || fail "a provider payload carried private text or unexpected fields"
import json, sys
secrets = ['SECRET-TITLE', 'SECRET-MILK', 'SECRET-HOME', 'SECRET-CODE', 'SECRET-ALICE', 'Alice']
allowed = {'type', 'householdId', 'taskId'}
n = 0
for line in open(sys.argv[1], encoding='utf-8'):
    if not line.strip(): continue
    e = json.loads(line); raw = json.dumps(e['body'])
    for s in secrets:
        assert s not in raw, f'{s} leaked to {e["provider"]}'
    if e['provider'] == 'fcm':
        m = e['body']['message']
        assert m['notification'] == {'title': 'Household OS', 'body': 'You have a new update'}, m['notification']
        assert set(m['data']) <= allowed, m['data']
    else:
        a = e['body']['aps']['alert']
        assert a == {'title': 'Household OS', 'body': 'You have a new update'}, a
        assert set(e['body']['payload']) <= allowed, e['body']['payload']
    n += 1
assert n > 0
print(f'checked {n} provider payloads')
PY
pass "FCM and APNs payloads contain only the generic text and routing ids (no names, titles, household text or codes)"

psql_ -c "select count(*) from device_push_tokens where token like 'tokUNREGandroid%'" | grep -q '^0$' || fail "an unregistered FCM token was kept"
psql_ -c "select count(*) from device_push_tokens where token like 'tokUNREGios%'" | grep -q '^0$' || fail "an unregistered APNs token was kept"
psql_ -c "select count(*) from device_push_tokens where token like 'tokBADTOKEN%'" | grep -q '^0$' || fail "a malformed token was kept"
psql_ -c "select count(*) from device_push_tokens where token like 'tokOK2android%'" | grep -q '^1$' || fail "the same user's healthy device lost its token"
pass "tokens the provider reports as unregistered or malformed are removed; the user's other device keeps its token"

psql_ -c "select count(*) from device_push_tokens where token like 'tokBADPAYLOAD%'" | grep -q '^1$' || fail "a token was deleted because of a payload error"
[ "$(outbox "$R6" "failed_at is not null and attempt_count = 1")" = t ] || fail "a payload error was not closed as a permanent failure"
pass "a 400 about the message does NOT delete the (valid) token; the row is closed as failed"

for r in "$R1" "$R2" "$R3" "$R4" "$R5" "$R10"; do
  [ "$(outbox "$r" "processed_at is not null and claimed_at is null")" = t ] || fail "row $r was not recorded as processed"
done
[ "$(outbox "$R7" "processed_at is null and failed_at is null and attempt_count = 1 and claimed_at is null")" = t ] || fail "a transient failure was not left retryable"
[ "$(outbox "$R9" "processed_at is not null")" = t ] || fail "a row delivered to one device was retried for the other"
[ "$(sends tokOK9android000000000000000000000000010)" = 1 ] || fail "the healthy device got duplicates"
pass "success is recorded; a transient failure stays retryable; a row that reached one device is not repeated for it"

echo "=== retry policy"
OUT=$(invoke "$SERVICE"); [ "$(echo "$OUT" | status_of)" = 200 ] || fail "second run failed"
[ "$(outbox "$R7" "processed_at is not null")" = t ] || fail "a flaky send was not completed on retry"
[ "$(sends tokFLAKYandroid0000000000000000000000008)" = 2 ] || fail "expected the flaky token to be tried twice"
for i in 3 4 5; do invoke "$SERVICE" >/dev/null; done
[ "$(outbox "$R8" "failed_at is not null and attempt_count = 5")" = t ] || fail "a permanently failing send was not closed after 5 attempts"
BEFORE=$(sends tokDOWNandroid000000000000000000000000009)
invoke "$SERVICE" >/dev/null; invoke "$SERVICE" >/dev/null
[ "$(sends tokDOWNandroid000000000000000000000000009)" = "$BEFORE" ] || fail "a closed row was sent again"
[ "$BEFORE" = 5 ] || fail "expected 5 attempts, saw $BEFORE"
pass "a transient failure succeeds on retry (sent twice: at-least-once); a provider outage stops after exactly 5 attempts and is never retried again"

echo "=== crash recovery"
R11=$(mkrow 1 11)
psql_ -c "update notification_outbox set claimed_at = now() - interval '10 minutes', attempt_count = 1 where id = '$R11'" >/dev/null
invoke "$SERVICE" >/dev/null
[ "$(outbox "$R11" "processed_at is not null and attempt_count = 2")" = t ] || fail "a row stranded by a crashed worker was not recovered"
pass "a row left claimed by a crashed worker is delivered once its lease expires"

echo "=== concurrent workers"
before=$(total_sends)
mktoken 11 tokSLOWandroid00000000000000000000000013 android
for n in 21 22 23 24 25 26; do mkrow 11 "$n" >/dev/null; done
( invoke "$SERVICE" 25 > "$TMP/w1.out" ) &
W1=$!
( invoke "$SERVICE" 25 > "$TMP/w2.out" ) &
W2=$!
# Wait for these two only: a bare `wait` would also wait for the mock provider
# and the function server, which run until the end of the script.
wait "$W1" "$W2"
for n in 21 22 23 24 25 26; do
  [ "$(sends_with_data "$(TASK "$n")")" = 1 ] || fail "row $n was delivered $(sends_with_data "$(TASK "$n")") times by two concurrent workers"
done
CLAIMED=$(python - "$(winpath "$TMP/w1.out")" "$(winpath "$TMP/w2.out")" <<'PY'
import json, sys
total = 0
for p in sys.argv[1:]:
    lines = open(p, encoding='utf-8').read().strip().splitlines()
    total += json.loads(lines[0])['claimed']
print(total)
PY
)
[ "$CLAIMED" = 6 ] || fail "the two workers claimed $CLAIMED rows in total instead of 6"
[ "$(psql_ -c "select count(*) from notification_outbox where recipient_user_id = '$(U 11)' and processed_at is not null")" = 6 ] || fail "not every row was recorded"
pass "two simultaneous workers claimed 6 rows between them and delivered each exactly once"

echo "=== retention"
psql_ >/dev/null <<SQL
insert into notification_outbox (recipient_user_id, type, title, body, processed_at) values ('$(U 12)', 'zz', 'a', 'b', now() - interval '8 days');
insert into notification_outbox (recipient_user_id, type, title, body, failed_at) values ('$(U 12)', 'zz', 'a', 'b', now() - interval '15 days');
insert into notification_outbox (recipient_user_id, type, title, body, processed_at) values ('$(U 12)', 'zz', 'a', 'b', now() - interval '1 day');
SQL
invoke "$SERVICE" >/dev/null
[ "$(psql_ -c "select count(*) from notification_outbox where recipient_user_id = '$(U 12)' and type = 'zz'")" = 1 ] || fail "retention did not remove exactly the expired rows"
pass "processed rows older than 7 days and failed rows older than 14 days are deleted; recent ones are kept"

echo "=== stale registrations (freshness policy enabled)"
mkuser 13; mkuser 14
mktoken 13 tokOLDandroid00000000000000000000000014 android 40
mktoken 14 tokFRESHandroid000000000000000000000015 android 1
RO=$(mkrow 13 31); RF=$(mkrow 14 32)
start_worker 30
invoke "$SERVICE" >/dev/null
[ "$(sends tokOLDandroid00000000000000000000000014)" = 0 ] || fail "a stale registration received a notification"
[ "$(sends tokFRESHandroid000000000000000000000015)" = 1 ] || fail "a fresh registration did not receive its notification"
[ "$(psql_ -c "select count(*) from device_push_tokens where token like 'tokOLDandroid%'")" = 0 ] || fail "the stale registration was not pruned"
[ "$(outbox "$RO" "processed_at is not null")" = t ] || fail "the row of a user with only stale tokens was not closed"
pass "with PUSH_TOKEN_MAX_AGE_DAYS=30 a 40-day-old registration is skipped and removed, a 1-day-old one is delivered"

echo "=== nothing was changed outside the fixtures"
stop_worker
[ "$(psql_ -c "select count(*) from notification_outbox where id in ($BASE_IDS) and (processed_at is not null or attempt_count > 0 or failed_at is not null)")" = 0 ] \
  || fail "a pre-existing outbox row was touched"
pass "pre-existing pending outbox rows were never claimed, sent or modified"
