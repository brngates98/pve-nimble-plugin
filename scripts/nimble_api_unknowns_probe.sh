#!/usr/bin/env bash
# Probe a live HPE Nimble array for API behaviors documented as "verify on array" in
# docs/API_VALIDATION.md (explicit unknowns). Read-only by default; optional flags run
# mutating checks (initiator group create/delete, PUT multi_initiator).
#
# Requires: curl, jq
#
# Usage:
#   ./scripts/nimble_api_unknowns_probe.sh
#
# Prompts for API base URL, username, and password (same pattern as nimble_capacity_api_probe.sh).
# Environment (optional):
#   NIMBLE_VOL_ID   Volume UUID for filtered GETs and volume detail (default: first volume from GET volumes)
#   VERIFY_SSL=1    Enable TLS verification (default: curl -k)
#
# Optional mutating probes (off by default):
#   RUN_INLINE_IG_PROBE=1       POST initiator_groups with inline iscsi_initiators, then DELETE group
#   RUN_MULTI_INITIATOR_PUT=1   PUT volumes/:id { multi_initiator: true } then GET (needs NIMBLE_VOL_ID)
#
# Not automated here (too disruptive / environment-specific):
#   - PUT volumes/:id online=false vs online=false+force — compare 4.x vs 5.x on your firmware manually.
#
set -euo pipefail

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

section() {
  echo ""
  echo "===> $*"
  echo "--------------------------------------------------------------------------------"
}

# Normalize Nimble list payloads: data array, data.items, data.data, or single object with id.
jq_nimble_list='.data as $d |
  (if ($d | type) == "array" then $d
   elif ($d | type) == "object" and (($d.items // null) | type) == "array" then $d.items
   elif ($d | type) == "object" and (($d.data // null) | type) == "array" then $d.data
   elif ($d | type) == "object" and (($d.id // "") != "") then [$d]
   else [] end)'

api_get() {
  local path="$1"
  local out="$2"
  local code
  code=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$out" "$BASE/v1/$path" \
    -H "X-Auth-Token: $TOKEN")
  echo "$code"
}

api_post_json() {
  local path="$1"
  local body="$2"
  local out="$3"
  local code
  code=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$out" -X POST "$BASE/v1/$path" \
    -H "X-Auth-Token: $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$body")
  echo "$code"
}

api_put_json() {
  local path="$1"
  local body="$2"
  local out="$3"
  local code
  code=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$out" -X PUT "$BASE/v1/$path" \
    -H "X-Auth-Token: $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$body")
  echo "$code"
}

api_delete() {
  local path="$1"
  local out="$2"
  local code
  code=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$out" -X DELETE "$BASE/v1/$path" \
    -H "X-Auth-Token: $TOKEN")
  echo "$code"
}

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
  echo "No session_token in login response." >&2
  exit 1
fi

section "1) POST initiator_groups with inline iscsi_initiators"
if [[ "${RUN_INLINE_IG_PROBE:-}" == "1" ]]; then
  ig_name="pve-api-probe-ig-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  body=$(jq -n \
    --arg n "$ig_name" \
    '{data:{name:$n,access_protocol:"iscsi",iscsi_initiators:[{label:"probe",iqn:"iqn.1996-04.de.proxmox:api-probe"}]}}')
  code=$(api_post_json "initiator_groups" "$body" "$TMP/ig_post.json")
  if [[ "$code" == "201" || "$code" == "200" ]]; then
    ig_id=$(jq -r '.data.id // .id // empty' "$TMP/ig_post.json")
    echo "OK: POST accepted (HTTP $code). Group id: $ig_id"
    if [[ -n "$ig_id" && "$ig_id" != "null" ]]; then
      dcode=$(api_delete "initiator_groups/$ig_id" "$TMP/ig_del.json")
      echo "DELETE initiator_groups/$ig_id -> HTTP $dcode"
    fi
  else
    echo "POST failed or unexpected HTTP $code (inline iscsi_initiators may be rejected on this firmware)."
    head -c 2000 "$TMP/ig_post.json" 2>/dev/null || true
    echo ""
    echo "If rejected, use POST v1/initiators after creating an empty group (see docs/API_VALIDATION.md)."
  fi
else
  echo "Skipped (set RUN_INLINE_IG_PROBE=1 to POST a throwaway initiator group and DELETE it)."
fi

section "2) GET snapshots — filtered vs all"
code=$(api_get "snapshots" "$TMP/snap_all.json")
echo "GET snapshots -> HTTP $code"
snap_all=$(jq "$jq_nimble_list | length" "$TMP/snap_all.json")

VOL_ID="${NIMBLE_VOL_ID:-}"
if [[ -z "$VOL_ID" ]]; then
  api_get "volumes" "$TMP/vols.json" >/dev/null
  VOL_ID=$(jq -r "$jq_nimble_list | .[0].id // empty" "$TMP/vols.json")
fi
if [[ -z "$VOL_ID" || "$VOL_ID" == "null" ]]; then
  echo "No volume id (set NIMBLE_VOL_ID or ensure array has volumes). Skipping vol_id comparison."
else
  echo "Using volume id: $VOL_ID"
  # Match plugin: query param vol_id, URI-encoded
  code=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$TMP/snap_filt.json" -G "$BASE/v1/snapshots" \
    -H "X-Auth-Token: $TOKEN" \
    --data-urlencode "vol_id=$VOL_ID")
  echo "GET snapshots?vol_id=... -> HTTP $code"
  snap_filt=$(jq "$jq_nimble_list | length" "$TMP/snap_filt.json")
  echo "Snapshot count (all list):     $snap_all"
  echo "Snapshot count (vol_id filter): $snap_filt"
  if [[ "$snap_all" -eq "$snap_filt" ]] && [[ "$snap_all" -gt 0 ]]; then
    echo "Note: counts match with snapshots present — array may be ignoring vol_id filter, or only one volume has snaps."
  elif [[ "$snap_filt" -le "$snap_all" ]]; then
    echo "Filtered count <= full list (consistent with a working filter or subset)."
  fi
  # Cross-check: client-side filter on full list for this vol_id
  snap_manual=$(jq --arg vid "$VOL_ID" "$jq_nimble_list | map(select((.vol_id // \"\") == \$vid)) | length" "$TMP/snap_all.json")
  echo "Snapshots for this vol_id in unfiltered list (client filter): $snap_manual"
  if [[ "$snap_manual" != "$snap_filt" ]]; then
    echo "WARNING: server-filtered count ($snap_filt) != client-filtered count on full list ($snap_manual) — query param may not filter as expected."
  fi
fi

section "3) GET access_control_records — filtered vs all"
code=$(api_get "access_control_records" "$TMP/acr_all.json")
echo "GET access_control_records -> HTTP $code"
acr_all=$(jq "$jq_nimble_list | length" "$TMP/acr_all.json")
if [[ -n "${VOL_ID:-}" && "$VOL_ID" != "null" ]]; then
  code=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$TMP/acr_filt.json" -G "$BASE/v1/access_control_records" \
    -H "X-Auth-Token: $TOKEN" \
    --data-urlencode "vol_id=$VOL_ID")
  echo "GET access_control_records?vol_id=... -> HTTP $code"
  acr_filt=$(jq "$jq_nimble_list | length" "$TMP/acr_filt.json")
  acr_manual=$(jq --arg vid "$VOL_ID" "$jq_nimble_list | map(select((.vol_id // \"\") == \$vid)) | length" "$TMP/acr_all.json")
  echo "ACR count (all):     $acr_all"
  echo "ACR count (vol_id):  $acr_filt"
  echo "ACR for vol (manual): $acr_manual"
  if [[ "$acr_manual" != "$acr_filt" ]]; then
    echo "WARNING: server-filtered ACR count != client-filtered — vol_id query may be ignored or wrong shape."
  fi
else
  echo "No VOL_ID; skipped vol_id ACR comparison."
fi

section "4) GET volumes/:id — multi_initiator field"
if [[ -n "${VOL_ID:-}" && "$VOL_ID" != "null" ]]; then
  code=$(api_get "volumes/$VOL_ID" "$TMP/vol_detail.json")
  echo "GET volumes/$VOL_ID -> HTTP $code"
  jq -r '
    .data as $d |
    if ($d | type) == "object" then
      "multi_initiator present: " + (($d | has("multi_initiator")) | tostring) + "\n" +
      "multi_initiator value:   " + (($d.multi_initiator // "null") | tostring)
    else
      "Unexpected data shape"
    end
  ' "$TMP/vol_detail.json"
  if [[ "${RUN_MULTI_INITIATOR_PUT:-}" == "1" ]]; then
    put_body=$(jq -n '{data:{multi_initiator:true}}')
    code=$(api_put_json "volumes/$VOL_ID" "$put_body" "$TMP/vol_put.json")
    echo "PUT volumes/$VOL_ID {multi_initiator:true} -> HTTP $code"
    api_get "volumes/$VOL_ID" "$TMP/vol_after.json" >/dev/null
    jq -r '.data.multi_initiator // .data // .' "$TMP/vol_after.json" | head -c 500
    echo ""
  else
    echo "Skipped PUT (set RUN_MULTI_INITIATOR_PUT=1 to set multi_initiator true on this volume)."
  fi
else
  echo "No VOL_ID; skipped."
fi

section "5) GET arrays — top-level keys and first row field names"
code=$(api_get "arrays" "$TMP/arrays.json")
echo "GET arrays -> HTTP $code"
jq -r '
  .data as $d |
  (if ($d | type) == "array" then ($d[0] // {})
   elif ($d | type) == "object" and (($d.items // null) | type) == "array" then ($d.items[0] // {})
   elif ($d | type) == "object" and (($d.data // null) | type) == "array" then ($d.data[0] // {})
   elif ($d | type) == "object" and (($d.id // "") != "") then $d
   else {} end) as $row |
  "First row keys: " + (($row | keys | sort | join(", ")) // "(none)"),
  ("usable_capacity_bytes: " + (($row.usable_capacity_bytes // "absent") | tostring)),
  ("available_bytes:       " + (($row.available_bytes // "absent") | tostring)),
  ("vol_usage_bytes:       " + (($row.vol_usage_bytes // "absent") | tostring)),
  ("snap_usage_bytes:      " + (($row.snap_usage_bytes // "absent") | tostring))
' "$TMP/arrays.json"

section "6) Forced offline (manual)"
echo "Not executed: PUT volumes/:id with online:false vs online:false+force depends on cgroup/sessions and firmware."
echo "Record array software version from Nimble UI or support logs; compare behavior 4.x vs 5.x on your deployment."

section "Done"
echo "Raw JSON under: $TMP (removed on exit). Re-run with VERIFY_SSL=1 for strict TLS."
