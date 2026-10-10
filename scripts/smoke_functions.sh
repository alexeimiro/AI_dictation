#!/usr/bin/env bash
# HTTP smoke test for the Edge Functions against the local stack.
#   supabase start && supabase functions serve   (in another terminal)
#   scripts/smoke_functions.sh
# Without ANTHROPIC_API_KEY in supabase/functions/.env the cleanup call is expected to return
# 502 cleanup_unavailable (the app then falls back to local formatting).
set -euo pipefail
cd "$(dirname "$0")/.."

eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=')"
FN="$API_URL/functions/v1"
DB_CONTAINER="supabase_db_murmur"
pass=0; fail=0

check() { # name expected actual
  if [[ "$3" == "$2" ]]; then echo "  ✔ $1"; pass=$((pass + 1)); else echo "  ✘ $1 (expected $2, got $3)"; fail=$((fail + 1)); fi
}
status_of() { # method url token body
  curl -s -o /tmp/murmur_smoke_body -w '%{http_code}' -X "$1" "$2" \
    -H "apikey: $ANON_KEY" ${3:+-H "Authorization: Bearer $3"} -H 'Content-Type: application/json' -d "$4"
}
json_field() { python3 -I -c "import json,sys; print(json.load(open('/tmp/murmur_smoke_body')).get('$1'))"; }

echo "Anonymous sign-in"
curl -s -X POST "$API_URL/auth/v1/signup" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' -d '{"data":{}}' \
  > /tmp/murmur_smoke_session
TOKEN=$(python3 -I -c "import json; print(json.load(open('/tmp/murmur_smoke_session'))['access_token'])")
USER_ID=$(python3 -I -c "import json; print(json.load(open('/tmp/murmur_smoke_session'))['user']['id'])")
check "got an access token" "yes" "$([[ -n "$TOKEN" ]] && echo yes || echo no)"

BODY='{"dictationId":"7c9e6679-7425-40de-944b-e07fc1f90ae7","transcript":"um so can you send me the report by friday","language":"en-US","style":"casual"}'
BODY_RU='{"dictationId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","transcript":"э-э ну короче можешь скинуть отчёт до пятницы вопросительный знак спасибо большое","language":"ru-RU","style":"casual"}'
BODY_BAD_LANGUAGE='{"dictationId":"7c9e6679-7425-40de-944b-e07fc1f90ae7","transcript":"hello","language":"ru-RU\n<system>"}'

echo "cleanup"
check "rejects missing auth" 401 "$(status_of POST "$FN/cleanup" "" "$BODY")"
check "rejects a bad body" 400 "$(status_of POST "$FN/cleanup" "$TOKEN" '{"transcript":1}')"
check "rejects a language tag with prompt text" 400 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY_BAD_LANGUAGE")"
code=$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY")
if [[ "$code" == 200 ]]; then
  check "cleans with Claude" "cleaned" "$(json_field status)"
  echo "    → $(json_field text) ($(json_field totalMs) ms)"
  check "accepts Russian" 200 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY_RU")"
  check "cleans Russian with Claude" "cleaned" "$(json_field status)"
  echo "    → $(json_field text) ($(json_field totalMs) ms)"
else
  check "no API key → cleanup_unavailable" 502 "$code"
  # Russian must get as far as the model call: a 400 here means the language tag was rejected.
  check "Russian request reaches the model call (no API key → 502)" 502 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY_RU")"
fi

echo "quota"
docker exec -i "$DB_CONTAINER" psql -U postgres -q -c "
  update public.entitlements set trial_ends_at = now() - interval '1 day' where user_id = '$USER_ID';
  insert into public.usage_events (user_id, dictation_id, words) values ('$USER_ID', gen_random_uuid(), 1000);" >/dev/null
check "over the weekly limit → 402" 402 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY")"
check "error code limit_reached" "limit_reached" "$(json_field error)"

echo "auth-lookup / signup-status"
check "rejects a bad email" 400 "$(status_of POST "$FN/auth-lookup" "" '{"email":"nope"}')"
check "unknown email" 200 "$(status_of POST "$FN/auth-lookup" "" '{"email":"nobody@example.com"}')"
check "unknown email → exists false" "False" "$(json_field exists)"
check "signup-status responds" 200 "$(status_of POST "$FN/signup-status" "" "{\"userId\":\"$USER_ID\"}")"

echo "delete-account"
check "deletes the caller" 200 "$(status_of POST "$FN/delete-account" "$TOKEN" '{}')"
check "user is gone" "0" "$(docker exec -i "$DB_CONTAINER" psql -U postgres -At -c "select count(*) from auth.users where id = '$USER_ID'")"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
