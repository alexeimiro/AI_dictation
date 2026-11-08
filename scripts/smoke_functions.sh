#!/usr/bin/env bash
# HTTP smoke test for the Edge Functions against the local stack.
#   supabase start && supabase functions serve   (in another terminal; after a new migration,
#   supabase db reset first)
#   scripts/smoke_functions.sh
# Without OPENAI_API_KEY in supabase/functions/.env, the calls that would reach OpenAI are expected
# to return 503: cleanup_unavailable from cleanup (the app then falls back to local formatting) and
# dictate_unavailable from dictate (the app then falls back to on-device recognition).
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
# The Python type name of the reply's timings.<key>: int, bool, or NoneType when it's missing.
timing_type() { python3 -I -c "import json; print(type((json.load(open('/tmp/murmur_smoke_body')).get('timings') or {}).get('$1')).__name__)"; }
new_id() { python3 -I -c "import uuid; print(uuid.uuid4())"; }
dictate_of() { # token dictation-id [curl args…]: a POST to dictate, with x-murmur-dictation when given
  local token=$1 dictation=$2
  shift 2
  curl -s -o /tmp/murmur_smoke_body -w '%{http_code}' -X POST "$FN/dictate" -H "apikey: $ANON_KEY" \
    ${token:+-H "Authorization: Bearer $token"} ${dictation:+-H "x-murmur-dictation: $dictation"} "$@"
}
dictate_text() { # token dictation-id body: text mode
  dictate_of "$1" "$2" -H 'Content-Type: application/json' -d "$3"
}
dictate_body() { # dictation-id transcript: a text-mode translation from Russian into English
  printf '{"dictationId":"%s","transcript":"%s","language":"ru-RU","targetLanguage":"en-US","style":"casual"}' "$1" "$2"
}

echo "Anonymous sign-in"
curl -s -X POST "$API_URL/auth/v1/signup" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' -d '{"data":{}}' \
  > /tmp/murmur_smoke_session
TOKEN=$(python3 -I -c "import json; print(json.load(open('/tmp/murmur_smoke_session'))['access_token'])")
USER_ID=$(python3 -I -c "import json; print(json.load(open('/tmp/murmur_smoke_session'))['user']['id'])")
check "got an access token" "yes" "$([[ -n "$TOKEN" ]] && echo yes || echo no)"

BODY='{"dictationId":"7c9e6679-7425-40de-944b-e07fc1f90ae7","transcript":"um so can you send me the report by friday","language":"en-US","style":"casual"}'
BODY_RU='{"dictationId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","transcript":"э-э ну короче можешь скинуть отчёт до пятницы вопросительный знак спасибо большое","language":"ru-RU","style":"casual"}'
BODY_BAD_LANGUAGE='{"dictationId":"7c9e6679-7425-40de-944b-e07fc1f90ae7","transcript":"hello","language":"ru-RU\n<system>"}'
BODY_TRANSLATE='{"dictationId":"9b2f6c1e-3d4a-4c5b-8e6f-7a8b9c0d1e2f","transcript":"можешь скинуть отчёт до пятницы спасибо большое","language":"ru-RU","targetLanguage":"en-US","style":"casual"}'
BODY_BLANK='{"dictationId":"5d2c1f0a-8b7e-4c3d-9a6f-1e2d3c4b5a69","transcript":" ","language":"en-US","style":"casual"}'

echo "cleanup"
check "rejects missing auth" 401 "$(status_of POST "$FN/cleanup" "" "$BODY")"
check "rejects a bad body" 400 "$(status_of POST "$FN/cleanup" "$TOKEN" '{"transcript":1}')"
check "rejects a language tag with prompt text" 400 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY_BAD_LANGUAGE")"
# A blank transcript is answered after the preflight and before the model call, so the reply's
# timings can be checked without an OpenAI key.
check "answers a blank transcript" 200 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY_BLANK")"
check "blank transcript → reason empty" "empty" "$(json_field reason)"
for key in authMs preflightMs totalMs; do check "timings.$key is whole ms" int "$(timing_type "$key")"; done
check "timings.cold is a boolean" bool "$(timing_type cold)"
code=$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY")
if [[ "$code" == 200 ]]; then
  HAS_KEY=1
  check "cleans up English" "cleaned" "$(json_field status)"
  echo "    → $(json_field text) ($(json_field totalMs) ms)"
  check "times the model call" int "$(timing_type modelMs)"
  check "accepts Russian" 200 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY_RU")"
  check "cleans up Russian" "cleaned" "$(json_field status)"
  echo "    → $(json_field text) ($(json_field totalMs) ms)"
  # The app inserts a translation only when the reply echoes its target language.
  check "accepts a translation" 200 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY_TRANSLATE")"
  check "echoes the translation target" "en-US" "$(json_field targetLanguage)"
  check "translates Russian into English" "cleaned" "$(json_field status)"
  echo "    → $(json_field text) ($(json_field totalMs) ms)"
else
  HAS_KEY=0
  check "no API key → cleanup_unavailable" 503 "$code"
  check "error code cleanup_unavailable" "cleanup_unavailable" "$(json_field error)"
  # Russian must get as far as the model call: a 400 here means the language tag was rejected.
  check "Russian request reaches the model call (no API key → 503)" 503 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY_RU")"
  check "translation request reaches the model call (no API key → 503)" 503 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY_TRANSLATE")"
fi

echo "dictate"
# Each request names a new dictation: only a dictation's first call counts toward the rate limit.
ID=$(new_id)
check "rejects missing auth" 401 "$(dictate_text "" "$ID" "$(dictate_body "$ID" "привет")")"
check "rejects a missing x-murmur-dictation" 400 "$(dictate_text "$TOKEN" "" "$(dictate_body "$ID" "привет")")"
check "rejects a header naming another dictation" 400 "$(dictate_text "$TOKEN" "$(new_id)" "$(dictate_body "$ID" "привет")")"
check "warms up" 200 "$(dictate_of "$TOKEN" "" -H 'x-murmur-warm: 1' -d '')"
check "warm-up → warm: true" "True" "$(json_field warm)"
for key in authMs totalMs; do check "warm-up timings.$key is whole ms" int "$(timing_type "$key")"; done
# Like cleanup's: a blank transcript is answered after the preflight and before the model call, so
# the preflight RPC and the timings can be checked without an OpenAI key.
ID=$(new_id)
check "answers a blank transcript" 200 "$(dictate_text "$TOKEN" "$ID" "$(dictate_body "$ID" " ")")"
check "blank transcript → reason empty" "empty" "$(json_field reason)"
check "text mode has no transcript" "None" "$(json_field transcript)"
for key in authMs bodyMs preflightMs totalMs; do check "timings.$key is whole ms" int "$(timing_type "$key")"; done
ID=$(new_id)
code=$(dictate_text "$TOKEN" "$ID" "$(dictate_body "$ID" "можешь скинуть отчёт до пятницы спасибо большое")")
if [[ $HAS_KEY == 1 ]]; then
  check "translates in text mode" 200 "$code"
  check "echoes the translation target" "en-US" "$(json_field targetLanguage)"
  check "translates Russian into English" "cleaned" "$(json_field status)"
  echo "    → $(json_field text) ($(json_field totalMs) ms)"
else
  check "text mode without an API key → 503" 503 "$code"
  check "error code dictate_unavailable" "dictate_unavailable" "$(json_field error)"
fi
# Audio mode as the app sends it: the metadata part first, then a second of silence as raw WAV.
python3 -I -c "import wave; w = wave.open('/tmp/murmur_smoke_1s.wav', 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(32000)); w.close()"
ID=$(new_id)
printf '{"dictationId":"%s","format":"wav","language":null,"keywords":[],"targetLanguage":"en-US","style":"casual"}' "$ID" \
  > /tmp/murmur_smoke_metadata.json
code=$(dictate_of "$TOKEN" "$ID" -F 'metadata=</tmp/murmur_smoke_metadata.json;type=application/json' \
  -F 'audio=@/tmp/murmur_smoke_1s.wav;type=audio/wav')
if [[ $HAS_KEY == 1 ]]; then
  check "transcribes a second of silence" 200 "$code"
  check "silence → reason empty" "empty" "$(json_field reason)"
  check "times the transcription" int "$(timing_type transcribeMs)"
else
  check "audio mode without an API key → 503" 503 "$code"
fi
# The rate limit counts a dictation once, and the preflight refuses its calls after the sixth.
ID=$(new_id)
for _ in 1 2 3 4 5; do dictate_text "$TOKEN" "$ID" "$(dictate_body "$ID" " ")" >/dev/null; done
check "a dictation's 6th call is allowed" 200 "$(dictate_text "$TOKEN" "$ID" "$(dictate_body "$ID" " ")")"
check "its 7th → 429" 429 "$(dictate_text "$TOKEN" "$ID" "$(dictate_body "$ID" " ")")"
check "error code too_many_attempts" "too_many_attempts" "$(json_field error)"

echo "quota"
docker exec -i "$DB_CONTAINER" psql -U postgres -q -c "
  update public.entitlements set trial_ends_at = now() - interval '1 day' where user_id = '$USER_ID';
  insert into public.usage_events (user_id, dictation_id, words) values ('$USER_ID', gen_random_uuid(), 1000);" >/dev/null
check "over the weekly limit → 402" 402 "$(status_of POST "$FN/cleanup" "$TOKEN" "$BODY")"
check "error code limit_reached" "limit_reached" "$(json_field error)"
ID=$(new_id)
check "dictate over the weekly limit → 402" 402 "$(dictate_text "$TOKEN" "$ID" "$(dictate_body "$ID" "привет как дела")")"
check "dictate error code limit_reached" "limit_reached" "$(json_field error)"

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
