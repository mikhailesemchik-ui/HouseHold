#!/usr/bin/env bash
# Characterizes the GoTrue email-OTP behavior that F1b (email reverification
# before account deletion) is built on, against the ISOLATED local stack only.
#
# FINDING (isolated GoTrue v2.195.0, preserved on purpose): a code is refused
# when it is replayed AFTER a verification finished, but several verifications
# of one code that run AT THE SAME TIME can all succeed. In an earlier probe of
# 12 rounds x 3 simultaneous requests, exactly one request succeeded in 0
# rounds; two succeeded in 9 and three in 3. An OTP is therefore proof of email
# control, not an exactly-once lock. F1b relies on the trusted user identity,
# the confirmed email and idempotent database deletion instead. This also
# applies to ordinary email recovery (several sessions may be issued).
#
# This script ASSERTS what Auth does guarantee (identity binding, rejection of
# wrong / expired / replayed-after-finish codes, no user creation, no cross-user
# identity) and REPORTS the concurrent behavior as a measurement. It does not
# turn the known limitation into a failure and does not claim it away.
#
# Needs the stack to have email confirmation ON, code-only templates and a SHORT
# otp_expiry (15 seconds), plus mail capture. Disposable example.test users are
# created with the admin API and deleted afterwards. No code, token or session
# value is printed.
#
# Usage:
#   SB_WORKDIR=<local supabase project dir> DB_CONTAINER=supabase_db_hhsqltest \
#     bash supabase/tests/delete_account_otp_preflight.sh
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_hhsqltest}"
case "$DB_CONTAINER" in
  *hhsqltest*) ;;
  *) echo "refusing to run against $DB_CONTAINER" >&2; exit 2 ;;
esac
: "${SB_WORKDIR:?set SB_WORKDIR to the local supabase project directory}"
MAIL_URL="${MAIL_URL:-http://127.0.0.1:55424}"
case "$MAIL_URL" in
  http://127.0.0.1:55424) ;;
  *) echo "refusing to use mail capture at $MAIL_URL" >&2; exit 2 ;;
esac
OTP_EXPIRY_SECONDS=15
ROUNDS="${ROUNDS:-8}"

ENV_DUMP=$(cd "$SB_WORKDIR" && supabase status -o env 2>/dev/null)
ANON=$(echo "$ENV_DUMP" | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')
SERVICE=$(echo "$ENV_DUMP" | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')
API_URL="http://supabase_kong_${DB_CONTAINER#supabase_db_}:8000"
export MSYS_NO_PATHCONV=1
[ -n "$ANON" ] && [ -n "$SERVICE" ] || { echo "missing local keys" >&2; exit 2; }
# shellcheck source=lib_local_otp.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_local_otp.sh"
mail_available || { echo "mail capture is not reachable at $MAIL_URL" >&2; exit 2; }

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }
RUN="$$-$(date +%s)"
TMP=$(mktemp -d)
IDS=()
cleanup() {
  for id in "${IDS[@]:-}"; do
    [ -n "$id" ] && cx -s -o /dev/null -X DELETE "$API_URL/auth/v1/admin/users/$id" \
      -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

EA="otp-a-$RUN@example.test"
EB="otp-b-$RUN@example.test"
UA=$(admin_create_user "$EA" "Pre-$RUN-pw-1"); UB=$(admin_create_user "$EB" "Pre-$RUN-pw-1")
[ -n "$UA" ] && [ -n "$UB" ] || fail "could not create the disposable users"
IDS+=("$UA" "$UB")
clear_mail

echo "--- A: a code for an existing email; nobody is created"
USERS0=$(user_count)
NOBODY="nobody-$RUN@example.test"
[ "$(send_code "$NOBODY")" != 200 ] || echo "note: unknown address answered 200"
[ "$(user_count)" = "$USERS0" ] || fail "requesting a code for an unknown address created a user"
[ -z "$(code_for "$NOBODY")" ] || fail "mail was sent to an unknown address"
clear_mail; sleep 2
[ "$(send_code "$EA")" = 200 ] || fail "the code request was refused"
CA=$(code_for "$EA"); [ ${#CA} = 6 ] || fail "no 6-digit code arrived"
[ "$(user_count)" = "$USERS0" ] || fail "requesting a code created a user"
pass "a 6-digit code reaches an existing email; an unknown address creates no user and gets no mail"

echo "--- B: the right code verifies and names the expected user"
[ "$(verify_user_id "$EA" "$CA")" = "$UA" ] || fail "the verified user is not the expected one"
pass "verifyOtp(type=email) with the right code returns exactly that user's UUID"

echo "--- E: a code cannot be used again after a verification finished"
[ "$(verify_status "$EA" "$CA")" != 200 ] || fail "a used code verified a second time"
pass "sequential replay is refused"

echo "--- C: wrong codes are refused and do not burn the real code"
clear_mail; sleep 2
[ "$(send_code "$EA")" = 200 ] || fail "second code request refused"
CA2=$(code_for "$EA"); [ ${#CA2} = 6 ] || fail "no second code"
WRONG=$([ "$CA2" = 000000 ] && echo 111111 || echo 000000)
[ "$(verify_status "$EA" "$WRONG")" != 200 ] || fail "a wrong code verified"
[ "$(verify_status "$EA" "12ab56")" != 200 ] || fail "a malformed code verified"
[ "$(verify_status "$EA" "$CA2")" = 200 ] || fail "the real code was no longer valid (so the refusals above prove nothing)"
pass "wrong and malformed codes are refused; the real code was still live and verified afterwards"

echo "--- F: a code is bound to the email it was issued to"
clear_mail; sleep 2
[ "$(send_code "$EA")" = 200 ] || fail "code request for A refused"
CFA=$(code_for "$EA"); [ ${#CFA} = 6 ] || fail "no code for A"
clear_mail; sleep 2
[ "$(send_code "$EB")" = 200 ] || fail "code request for B refused"
CFB=$(code_for "$EB"); [ ${#CFB} = 6 ] || fail "no code for B"
[ "$(verify_status "$EA" "$CFB")" != 200 ] || fail "B's code verified A's email"
[ "$(verify_status "$EB" "$CFA")" != 200 ] || fail "A's code verified B's email"
[ "$(verify_user_id "$EB" "$CFB")" = "$UB" ] || fail "B's own code was no longer valid (cross-refusals prove nothing)"
[ "$(verify_user_id "$EA" "$CFA")" = "$UA" ] || fail "A's own code was no longer valid (cross-refusals prove nothing)"
pass "each code verifies only its own email, and was live when the cross attempts failed"

echo "--- D: an expired code"
clear_mail; sleep 2
[ "$(send_code "$EA")" = 200 ] || fail "code request refused"
CE=$(code_for "$EA"); [ ${#CE} = 6 ] || fail "no code"
sleep $((OTP_EXPIRY_SECONDS + 3))
[ "$(verify_status "$EA" "$CE")" != 200 ] || fail "an expired code verified"
pass "a code older than otp_expiry (${OTP_EXPIRY_SECONDS}s) is refused"

echo "--- G: simultaneous verifications of ONE code (characterization, not a guarantee)"
MULTI=0; ONE=0; ZERO=0; OTHER_USER=0; SESSIONS=0; TOTAL_OK=0; SEQ_REPLAY_OK=0
for ROUND in $(seq 1 "$ROUNDS"); do
  clear_mail; sleep 2
  [ "$(send_code "$EA")" = 200 ] || fail "code request refused (round $ROUND)"
  CG=$(code_for "$EA"); [ ${#CG} = 6 ] || fail "no code (round $ROUND)"
  for i in 1 2 3; do (verify_summary "$EA" "$CG" > "$TMP/r$i") & done
  wait
  OK=0; : > "$TMP/sess"
  for i in 1 2 3; do
    read -r ST UID_ SESS < "$TMP/r$i"
    if [ "$ST" = 200 ]; then
      OK=$((OK + 1))
      [ "$UID_" = "$UA" ] || OTHER_USER=$((OTHER_USER + 1))
      echo "$SESS" >> "$TMP/sess"
    fi
  done
  TOTAL_OK=$((TOTAL_OK + OK))
  SESSIONS=$((SESSIONS + $(sort -u "$TMP/sess" | wc -l)))
  case $OK in 0) ZERO=$((ZERO + 1));; 1) ONE=$((ONE + 1));; *) MULTI=$((MULTI + 1));; esac
  [ "$(verify_status "$EA" "$CG")" != 200 ] || SEQ_REPLAY_OK=$((SEQ_REPLAY_OK + 1))
done
echo "MEASURED over $ROUNDS rounds of 3 simultaneous requests with one code:"
echo "  rounds where exactly one succeeded: $ONE; more than one: $MULTI; none: $ZERO"
echo "  successful verifications: $TOTAL_OK, distinct sessions issued among them: $SESSIONS"
[ "$OTHER_USER" = 0 ] || fail "a simultaneous verification returned a user other than the code's owner ($OTHER_USER times)"
[ "$SEQ_REPLAY_OK" = 0 ] || fail "a code verified again AFTER the simultaneous requests had finished ($SEQ_REPLAY_OK times)"
[ "$ZERO" = 0 ] || fail "$ZERO rounds had no successful verification although the code was live"
pass "every successful simultaneous verification returned the owner's UUID; none leaked another user; replay after completion was refused"
if [ "$MULTI" -gt 0 ]; then
  echo "NOTE (known Auth limitation): $MULTI of $ROUNDS rounds accepted one code more than once."
  echo "      An OTP is NOT an exactly-once lock; F1b relies on identity + idempotent deletion."
fi

echo "--- H: a verification leaves the user's existing session working and creates no user"
TOK=$(password_token "$EB" "Pre-$RUN-pw-1")
[ -n "$TOK" ] || fail "no existing session"
clear_mail; sleep 2
[ "$(send_code "$EB")" = 200 ] || fail "code request refused"
CH=$(code_for "$EB"); [ "$(verify_status "$EB" "$CH")" = 200 ] || fail "verification failed"
[ "$(cx -s -o /dev/null -w '%{http_code}' -H "apikey: $ANON" -H "Authorization: Bearer $TOK" "$API_URL/auth/v1/user")" = 200 ] \
  || fail "the existing session was invalidated by a verification"
[ "$(user_count)" = "$USERS0" ] || fail "verification created a user"
pass "a verification issues its own session; the caller's existing session and the user count are untouched"
