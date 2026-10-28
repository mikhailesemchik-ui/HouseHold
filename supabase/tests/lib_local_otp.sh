#!/usr/bin/env bash
# Shared helpers for the local email-OTP tests (F1b). Source it after setting
# DB_CONTAINER, API_URL, ANON, SERVICE and MAIL_URL. ISOLATED local stack only.
# Nothing here prints a code, token or session value.

cx() { docker exec -i "$DB_CONTAINER" curl "$@"; }
jget() { python -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }
mail() { curl -s "$MAIL_URL$1" "${@:2}"; }
clear_mail() { mail /api/v1/messages -X DELETE >/dev/null; }
mail_available() { [ "$(curl -s -o /dev/null -w '%{http_code}' "$MAIL_URL/api/v1/messages" 2>/dev/null)" = 200 ]; }

# Newest 6-digit code mailed to $1 (waits up to ~10s). Prints only the code.
code_for() {
  local addr="$1" i id
  for i in $(seq 1 20); do
    id=$(mail /api/v1/messages | python -c "
import sys, json
for m in json.load(sys.stdin).get('messages', []):
    if any(t['Address'].lower() == '$addr'.lower() for t in m['To']):
        print(m['ID']); break
")
    if [ -n "$id" ]; then
      mail "/api/v1/message/$id" | python -c "
import sys, json, re
m = re.search(r'\b(\d{6})\b', json.load(sys.stdin)['Text'])
print(m.group(1) if m else '')
"
      return
    fi
    sleep 0.5
  done
}

# Admin-create a confirmed email user. Prints its id.
admin_create_user() { # email password
  cx -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SERVICE" \
    -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$2\",\"email_confirm\":true}" | jget "['id']"
}
password_token() { # email password -> access token of an ordinary session
  cx -s -X POST "$API_URL/auth/v1/token?grant_type=password" -H "apikey: $ANON" \
    -H "Content-Type: application/json" -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jget "['access_token']"
}
user_count() {
  cx -s "$API_URL/auth/v1/admin/users?per_page=1000" -H "apikey: $SERVICE" \
    -H "Authorization: Bearer $SERVICE" | python -c "import sys,json; print(len(json.load(sys.stdin)['users']))"
}
send_code() { # email -> http status (create_user=false: never registers anyone)
  cx -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/auth/v1/otp" -H "apikey: $ANON" \
    -H "Content-Type: application/json" -d "{\"email\":\"$1\",\"create_user\":false}"
}
verify_status() { # email code -> http status; body discarded
  cx -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/auth/v1/verify" -H "apikey: $ANON" \
    -H "Content-Type: application/json" -d "{\"type\":\"email\",\"email\":\"$1\",\"token\":\"$2\"}"
}
# email code -> "<status> <user id or -> <8 hex of the session's refresh-token hash or ->"
# (a hash prefix, enough to tell sessions apart, useless as a credential).
verify_summary() {
  cx -s -w '\nHTTP=%{http_code}' -X POST "$API_URL/auth/v1/verify" -H "apikey: $ANON" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"email\",\"email\":\"$1\",\"token\":\"$2\"}" | python -c "
import sys, json, hashlib
raw = sys.stdin.read()
body, _, status = raw.rpartition('HTTP=')
uid = sess = '-'
try:
    d = json.loads(body)
    uid = d['user']['id']
    sess = hashlib.sha256(d['refresh_token'].encode()).hexdigest()[:8]
except Exception:
    pass
print(status.strip(), uid, sess)
"
}
verify_user_id() { verify_summary "$@" | awk '{print $2}'; }
