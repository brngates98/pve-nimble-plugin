#!/usr/bin/env bash
# Poll HPE Nimble REST API endpoints used for PVE storage status() / capacity reporting.
# Prompts for URL, username, password; writes one JSON file (session token redacted).
#
# Requires: curl, jq
# Usage: ./scripts/nimble_capacity_api_probe.sh [output.json]
#   VERIFY_SSL=1  — use TLS verification (default: insecure -k for lab arrays)
#
set -euo pipefail

OUT="${1:-nimble-capacity-probe-$(date -u +%Y%m%dT%H%M%SZ).json}"
CURL_OPTS=( -sS )
if [[ "${VERIFY_SSL:-}" != "1" ]]; then
  CURL_OPTS+=( -k )
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: missing required command: $1" >&2
    exit 1
  }
}

need_cmd curl
need_cmd jq

read -rp "Nimble API base URL [https://array.example.com:5392]: " BASE
BASE=${BASE:-https://array.example.com:5392}
BASE=${BASE%/}
BASE=${BASE%/v1}

read -rp "API username: " USERNAME
read -srp "API password: " PASSWORD
echo

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

LOGIN_BODY=$(jq -n --arg u "$USERNAME" --arg p "$PASSWORD" '{data:{username:$u,password:$p}}')
HTTP_CODE=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$TMP/login.json" -X POST "$BASE/v1/tokens" \
  -H 'Content-Type: application/json' \
  -d "$LOGIN_BODY")

if [[ "$HTTP_CODE" != "201" && "$HTTP_CODE" != "200" ]]; then
  echo "Login failed (HTTP $HTTP_CODE). Response:" >&2
  cat "$TMP/login.json" >&2 || true
  exit 1
fi

TOKEN=$(jq -r '.data.session_token // .session_token // empty' "$TMP/login.json")
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "No session_token in login response:" >&2
  jq . "$TMP/login.json" >&2 || cat "$TMP/login.json" >&2
  exit 1
fi

curl "${CURL_OPTS[@]}" -o "$TMP/pools.json" "$BASE/v1/pools" \
  -H "X-Auth-Token: $TOKEN"

curl "${CURL_OPTS[@]}" -o "$TMP/arrays.json" "$BASE/v1/arrays" \
  -H "X-Auth-Token: $TOKEN"

# Pool IDs from list (same shapes as plugin nimble_data_as_list: array, items[], data[], single object with id)
jq -r '
  .data as $d |
  (if ($d | type) == "array" then $d
   elif ($d | type) == "object" and (($d.items // null) | type) == "array" then $d.items
   elif ($d | type) == "object" and (($d.data // null) | type) == "array" then $d.data
   elif ($d | type) == "object" and ($d.id // "") != "" then [$d]
   else [] end) |
  .[] | select(type == "object") | .id // empty | strings
' "$TMP/pools.json" | sort -u > "$TMP/pool_ids.txt"

POOLS_DETAIL='[]'
while read -r pid; do
  [[ -z "$pid" ]] && continue
  f="$TMP/pool_${pid}.json"
  curl "${CURL_OPTS[@]}" -o "$f" "$BASE/v1/pools/${pid}" \
    -H "X-Auth-Token: $TOKEN"
  POOLS_DETAIL=$(jq --arg id "$pid" --slurpfile body "$f" \
    '. + [{id: $id, http_path: ("pools/" + $id), response: $body[0]}]' <<< "$POOLS_DETAIL")
done < "$TMP/pool_ids.txt"

# Redact token (no jq walk — works on older jq)
LOGIN_REDACTED=$(jq '
  if (.data | type) == "object" and (.data | has("session_token")) then .data.session_token = "<redacted>" else . end
  | if has("session_token") then .session_token = "<redacted>" else . end
' "$TMP/login.json")

jq -n \
  --arg base_url "$BASE" \
  --arg generated_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg script "nimble_capacity_api_probe.sh" \
  --arg note "Password never stored. session_token redacted. Endpoints: POST v1/tokens, GET v1/pools, GET v1/pools/:id, GET v1/arrays." \
  --argjson login "$LOGIN_REDACTED" \
  --argjson pools_list "$(cat "$TMP/pools.json")" \
  --argjson pools_detail "$POOLS_DETAIL" \
  --argjson arrays "$(cat "$TMP/arrays.json")" \
  '{
    meta: {
      nimble_api_base: $base_url,
      generated_utc: $generated_utc,
      script: $script,
      note: $note,
      pool_ids_fetched: ($pools_detail | map(.id))
    },
    post_v1_tokens_response: $login,
    get_v1_pools_response: $pools_list,
    get_v1_pools_by_id: $pools_detail,
    get_v1_arrays_response: $arrays
  }' > "$OUT"

echo "Wrote $OUT"
echo "Pool detail rows: $(jq '.get_v1_pools_by_id | length' "$OUT")"
