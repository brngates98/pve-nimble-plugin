#!/usr/bin/env bash
# Probe a live HPE Nimble array for API behaviors documented as "verify on array" in
# docs/API_VALIDATION.md (explicit unknowns). Writes one structured JSON object to a file
# (default: nimble-unknowns-probe-<UTC-timestamp>.json in cwd); optional argument overrides path.
# Prints "Wrote <path>" to stderr on success (same pattern as nimble_capacity_api_probe.sh).
#
# Requires: curl, jq
#
# Usage:
#   ./scripts/nimble_api_unknowns_probe.sh [output.json]
#
# Prompts for API base URL, username, and password (same pattern as nimble_capacity_api_probe.sh).
# Probe volume id is discovered automatically (no input): first row of GET volumes, else first vol_id
# from GET access_control_records. Optional NIMBLE_VOL_ID overrides for a specific volume.
# Environment (optional):
#   NIMBLE_VOL_ID   Override discovered volume id (optional)
#   VERIFY_SSL=1    Enable TLS verification (default: curl -k)
#
# Optional mutating probes (off by default):
#   RUN_INLINE_IG_PROBE=1       POST initiator_groups with inline iscsi_initiators, then DELETE group
#   RUN_MULTI_INITIATOR_PUT=1   PUT volumes/:id { multi_initiator: true } then GET (needs a volume)
#
# Not automated here (too disruptive / environment-specific):
#   - PUT volumes/:id online=false vs online:false+force — compare 4.x vs 5.x on your firmware manually.
#
set -euo pipefail

OUT="${1:-nimble-unknowns-probe-$(date -u +%Y%m%dT%H%M%SZ).json}"

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

# Normalize Nimble list payloads: data array, data.items, data.data, or single object with id.
jq_nimble_list='.data as $d |
  (if ($d | type) == "array" then $d
   elif ($d | type) == "object" and (($d.items // null) | type) == "array" then $d.items
   elif ($d | type) == "object" and (($d.data // null) | type) == "array" then $d.data
   elif ($d | type) == "object" and (($d.id // "") != "") then [$d]
   else [] end)'

jq_first_row='
  .data as $d |
  (if ($d | type) == "array" then ($d[0] // {})
   elif ($d | type) == "object" and (($d.items // null) | type) == "array" then ($d.items[0] // {})
   elif ($d | type) == "object" and (($d.data // null) | type) == "array" then ($d.data[0] // {})
   elif ($d | type) == "object" and (($d.id // "") != "") then $d
   else {} end)
'

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
  jq -n \
    --arg base "$BASE" \
    --argjson http "$(jq -n --arg c "$HTTP_CODE" '$c | tonumber')" \
    --arg snippet "$(head -c 4000 "$TMP/login.json" 2>/dev/null || true)" \
    '{error:"login_failed",meta:{nimble_api_base:$base},login:{http_code:$http,ok:false,response_snippet:$snippet}}' >&2
  echo "Login failed (HTTP $HTTP_CODE)." >&2
  exit 1
fi

TOKEN=$(jq -r '.data.session_token // .session_token // empty' "$TMP/login.json")
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo '{"error":"no_session_token","login":{"ok":false}}' >&2
  exit 1
fi

# Pick a volume id for filtered GETs (no user input): volumes list first, else ACR vol_id sample.
ACR_PREFETCHED=0
code_acr_all=""
VOL_ID="${NIMBLE_VOL_ID:-}"
VOL_ID_SOURCE="none"
if [[ -n "$VOL_ID" ]]; then
  VOL_ID_SOURCE="environment"
fi
if [[ -z "$VOL_ID" ]]; then
  code_vols=$(api_get "volumes" "$TMP/vols.json")
  if [[ "$code_vols" =~ ^2[0-9][0-9]$ ]]; then
    VOL_ID=$(jq -r "$jq_nimble_list | .[0].id // empty" "$TMP/vols.json")
    if [[ -n "$VOL_ID" && "$VOL_ID" != "null" ]]; then
      VOL_ID_SOURCE="volumes_list"
    fi
  fi
fi
if [[ -z "$VOL_ID" || "$VOL_ID" == "null" ]]; then
  code_acr_all=$(api_get "access_control_records" "$TMP/acr_all.json")
  ACR_PREFETCHED=1
  if [[ "$code_acr_all" =~ ^2[0-9][0-9]$ ]]; then
    VOL_ID=$(jq -r "$jq_nimble_list | [ .[] | (.vol_id // null | tostring) | select(length > 0) ] | .[0] // empty" "$TMP/acr_all.json")
    if [[ -n "$VOL_ID" && "$VOL_ID" != "null" ]]; then
      VOL_ID_SOURCE="access_control_records"
    fi
  fi
fi

# --- 1) Initiator group inline probe ---
IG_JSON='{}'
if [[ "${RUN_INLINE_IG_PROBE:-}" == "1" ]]; then
  ig_name="pve-api-probe-ig-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  body=$(jq -n \
    --arg n "$ig_name" \
    '{data:{name:$n,access_protocol:"iscsi",iscsi_initiators:[{label:"probe",iqn:"iqn.1996-04.de.proxmox:api-probe"}]}}')
  post_code=$(api_post_json "initiator_groups" "$body" "$TMP/ig_post.json")
  ig_id=$(jq -r '.data.id // .id // empty' "$TMP/ig_post.json")
  del_code=""
  delete_attempted=false
  if [[ "$post_code" == "201" || "$post_code" == "200" ]] && [[ -n "$ig_id" && "$ig_id" != "null" ]]; then
    delete_attempted=true
    del_code=$(api_delete "initiator_groups/$ig_id" "$TMP/ig_del.json")
  fi
  post_snip="$(head -c 2000 "$TMP/ig_post.json" 2>/dev/null || true)"
  if [[ -n "$del_code" ]]; then
    del_http_json=$(jq -n --arg c "$del_code" '$c | tonumber')
  else
    del_http_json=null
  fi
  IG_JSON=$(jq -n \
    --arg name "$ig_name" \
    --argjson post_http "$(jq -n --arg c "$post_code" '$c | tonumber')" \
    --arg ig_id "${ig_id:-}" \
    --argjson delete_http "$del_http_json" \
    --argjson delete_attempted "$( [[ "$delete_attempted" == "true" ]] && echo true || echo false )" \
    --arg post_snip "$post_snip" \
    '{
      skipped: false,
      initiator_group_name: $name,
      post_http_code: $post_http,
      initiator_group_id: (if ($ig_id | length) > 0 then $ig_id else null end),
      delete_http_code: $delete_http,
      delete_attempted: $delete_attempted,
      post_response_snippet: $post_snip
    }')
else
  IG_JSON=$(jq -n '{skipped:true,reason:"set RUN_INLINE_IG_PROBE=1 to POST a throwaway group and DELETE it"}')
fi

# --- Snapshots ---
code_snap_all=$(api_get "snapshots" "$TMP/snap_all.json")
count_snap_all=$(jq "$jq_nimble_list | length" "$TMP/snap_all.json")

SNAP_JSON='{}'
if [[ -z "$VOL_ID" || "$VOL_ID" == "null" ]]; then
  SNAP_JSON=$(jq -n \
    --argjson http "$(echo "$code_snap_all" | jq -n --arg c "$code_snap_all" '$c|tonumber')" \
    --argjson count_all "$count_snap_all" \
    '{
      volume_id: null,
      get_all_http_code: $http,
      snapshot_count_all: $count_all,
      skipped_vol_id_tests: true,
      reason: "no_volume_id_after_GET_volumes_and_GET_access_control_records"
    }')
else
  code_snap_f=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$TMP/snap_filt.json" -G "$BASE/v1/snapshots" \
    -H "X-Auth-Token: $TOKEN" \
    --data-urlencode "vol_id=$VOL_ID")
  count_snap_f=$(jq "$jq_nimble_list | length" "$TMP/snap_filt.json")
  snap_all_snip="$(head -c 800 "$TMP/snap_all.json" 2>/dev/null || true)"
  # Compare vol_id as strings (API may return number or string).
  jq_vol_match='map(select(((.vol_id // null) | tostring) == $vid)) | length'
  if [[ "$code_snap_all" =~ ^2[0-9][0-9]$ ]]; then
    count_snap_manual=$(jq --arg vid "$VOL_ID" "$jq_nimble_list | $jq_vol_match" "$TMP/snap_all.json")
    count_snap_all=$(jq "$jq_nimble_list | length" "$TMP/snap_all.json")
    filter_matches_client=$(( count_snap_manual == count_snap_f ? 1 : 0 ))
    SNAP_JSON=$(jq -n \
      --arg vid "$VOL_ID" \
      --arg snip "$snap_all_snip" \
      --argjson http_all "$(jq -n --arg c "$code_snap_all" '$c | tonumber')" \
      --argjson http_filt "$(jq -n --arg c "$code_snap_f" '$c | tonumber')" \
      --argjson count_all "$count_snap_all" \
      --argjson count_filtered "$count_snap_f" \
      --argjson count_client_side "$count_snap_manual" \
      --argjson filter_matches_client "$filter_matches_client" \
      '{
      volume_id: $vid,
      get_all_http_code: $http_all,
      get_filtered_http_code: $http_filt,
      get_all_ok: true,
      get_all_error_snippet: null,
      snapshot_count_all: $count_all,
      snapshot_count_server_filtered: $count_filtered,
      snapshot_count_client_filtered_on_full_list: $count_client_side,
      server_filter_matches_client_enumeration: ($filter_matches_client == 1),
      note: (if ($count_all > 0) and ($count_all == $count_filtered) then "equal_counts_may_mean_ignored_filter_or_single_volume_snaps" else null end)
    }')
  else
    filter_matches_client=0
    SNAP_JSON=$(jq -n \
      --arg vid "$VOL_ID" \
      --arg snip "$snap_all_snip" \
      --argjson http_all "$(jq -n --arg c "$code_snap_all" '$c | tonumber')" \
      --argjson http_filt "$(jq -n --arg c "$code_snap_f" '$c | tonumber')" \
      --argjson count_filtered "$count_snap_f" \
      --argjson filter_matches_client "$filter_matches_client" \
      '{
      volume_id: $vid,
      get_all_http_code: $http_all,
      get_filtered_http_code: $http_filt,
      get_all_ok: false,
      get_all_error_snippet: $snip,
      snapshots_read_requires_query_filter: ($snip | test("SM_missing_arg")),
      snapshot_count_all: null,
      snapshot_count_server_filtered: $count_filtered,
      snapshot_count_client_filtered_on_full_list: null,
      server_filter_matches_client_enumeration: null,
      note: (if ($snip | test("SM_missing_arg")) then "firmware_rejects_unfiltered_GET_snapshots_plugin_sync_uses_per_vol_id_GET" else "get_all_snapshots_non_2xx_client_counts_skipped_use_filtered_row_only" end)
    }')
  fi
fi

# --- ACR ---
if [[ "$ACR_PREFETCHED" != "1" ]]; then
  code_acr_all=$(api_get "access_control_records" "$TMP/acr_all.json")
fi
count_acr_all=$(jq "$jq_nimble_list | length" "$TMP/acr_all.json")

ACR_JSON='{}'
if [[ -z "$VOL_ID" || "$VOL_ID" == "null" ]]; then
  ACR_JSON=$(jq -n \
    --argjson http "$(echo "$code_acr_all" | jq -n --arg c "$code_acr_all" '$c|tonumber')" \
    --argjson count "$count_acr_all" \
    '{
      volume_id: null,
      get_all_http_code: $http,
      acr_count_all: $count,
      skipped_vol_id_tests: true
    }')
else
  code_acr_f=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$TMP/acr_filt.json" -G "$BASE/v1/access_control_records" \
    -H "X-Auth-Token: $TOKEN" \
    --data-urlencode "vol_id=$VOL_ID")
  count_acr_f=$(jq "$jq_nimble_list | length" "$TMP/acr_filt.json")
  # List rows may use vol_id and/or volume_id (match plugin-style string compare).
  count_acr_manual=$(jq --arg vid "$VOL_ID" "$jq_nimble_list | map(select(((.vol_id // .volume_id // null) | tostring) == \$vid)) | length" "$TMP/acr_all.json")
  acr_match=$(( count_acr_manual == count_acr_f ? 1 : 0 ))
  ACR_JSON=$(jq -n \
    --arg vid "$VOL_ID" \
    --argjson http_all "$(echo "$code_acr_all" | jq -n --arg c "$code_acr_all" '$c|tonumber')" \
    --argjson http_filt "$(echo "$code_acr_f" | jq -n --arg c "$code_acr_f" '$c|tonumber')" \
    --argjson count_all "$count_acr_all" \
    --argjson count_f "$count_acr_f" \
    --argjson count_manual "$count_acr_manual" \
    --argjson match "$acr_match" \
    '{
      volume_id: $vid,
      get_all_http_code: $http_all,
      get_filtered_http_code: $http_filt,
      acr_count_all: $count_all,
      acr_count_server_filtered: $count_f,
      acr_count_client_filtered_on_full_list: $count_manual,
      server_filter_matches_client_enumeration: ($match == 1),
      client_filter_uses_fields: ["vol_id", "volume_id"]
    }')
fi

# --- Volume multi_initiator ---
VOL_JSON='{}'
if [[ -n "$VOL_ID" && "$VOL_ID" != "null" ]]; then
  code_vol=$(api_get "volumes/$VOL_ID" "$TMP/vol_detail.json")
  mi_present=$(jq -c "$jq_first_row | if type == \"object\" then has(\"multi_initiator\") else false end" "$TMP/vol_detail.json")
  mi_val=$(jq -c "$jq_first_row | if type == \"object\" then .multi_initiator else null end" "$TMP/vol_detail.json")
  PUT_JSON='{"skipped":true}'
  if [[ "${RUN_MULTI_INITIATOR_PUT:-}" == "1" ]]; then
    put_body=$(jq -n '{data:{multi_initiator:true}}')
    put_code=$(api_put_json "volumes/$VOL_ID" "$put_body" "$TMP/vol_put.json")
    api_get "volumes/$VOL_ID" "$TMP/vol_after.json" >/dev/null
    mi_after=$(jq -c "$jq_first_row | if type == \"object\" then .multi_initiator else null end" "$TMP/vol_after.json")
    put_snip="$(head -c 1500 "$TMP/vol_put.json" 2>/dev/null || true)"
    PUT_JSON=$(jq -n \
      --argjson put_http "$(jq -n --arg c "$put_code" '$c | tonumber')" \
      --argjson mi_after "$mi_after" \
      --arg put_snip "$put_snip" \
      '{skipped:false,put_http_code:$put_http,multi_initiator_after_get:$mi_after,put_response_snippet:$put_snip}')
  fi
  VOL_JSON=$(jq -n \
    --arg vid "$VOL_ID" \
    --argjson http "$(jq -n --arg c "$code_vol" '$c | tonumber')" \
    --argjson mi_present "$mi_present" \
    --argjson mi_value "$mi_val" \
    --argjson put_block "$PUT_JSON" \
    '{
      volume_id: $vid,
      get_http_code: $http,
      multi_initiator_field_present: $mi_present,
      multi_initiator_value_before_put: $mi_value,
      multi_initiator_put_probe: $put_block
    }')
else
  VOL_JSON=$(jq -n '{skipped:true,reason:"no volume id"}')
fi

# --- Arrays ---
code_arrays=$(api_get "arrays" "$TMP/arrays.json")
ARRAY_ROW=$(jq -c "$jq_first_row" "$TMP/arrays.json")
ARRAYS_JSON=$(jq -n \
  --argjson http "$(jq -n --arg c "$code_arrays" '$c | tonumber')" \
  --argjson row "$ARRAY_ROW" \
  '{
    get_http_code: $http,
    first_row_keys: (if ($row|type)=="object" and ($row|keys|length)>0 then ($row|keys|sort) else [] end),
    fields: {
      usable_capacity_bytes: (if ($row|type)=="object" then $row.usable_capacity_bytes else null end),
      available_bytes: (if ($row|type)=="object" then $row.available_bytes else null end),
      vol_usage_bytes: (if ($row|type)=="object" then $row.vol_usage_bytes else null end),
      snap_usage_bytes: (if ($row|type)=="object" then $row.snap_usage_bytes else null end)
    },
    note: (if ($row|type)=="object" and (($row|keys|length) <= 2) then "list_row_may_be_summary_try_get_arrays_id_for_capacity_fields" else null end)
  }')

# --- Assemble report ---
REPORT=$(jq -n \
  --arg base "$BASE" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg script "nimble_api_unknowns_probe.sh" \
  --arg output_file "$OUT" \
  --arg volume_id_source "$VOL_ID_SOURCE" \
  --arg volume_id "${VOL_ID:-}" \
  --argjson verify_ssl "$( [[ "${VERIFY_SSL:-}" == "1" ]] && echo true || echo false )" \
  --argjson run_ig "$( [[ "${RUN_INLINE_IG_PROBE:-}" == "1" ]] && echo true || echo false )" \
  --argjson run_mi_put "$( [[ "${RUN_MULTI_INITIATOR_PUT:-}" == "1" ]] && echo true || echo false )" \
  --argjson login_http "$(jq -n --arg c "$HTTP_CODE" '$c | tonumber')" \
  --argjson ig "$IG_JSON" \
  --argjson snap "$SNAP_JSON" \
  --argjson acr "$ACR_JSON" \
  --argjson volume_multi_initiator "$VOL_JSON" \
  --argjson arrays "$ARRAYS_JSON" \
  '{
    meta: {
      nimble_api_base: $base,
      generated_utc: $generated,
      script: $script,
      output_file: $output_file,
      volume_id_used: (if ($volume_id|length)>0 then $volume_id else null end),
      volume_id_source: $volume_id_source,
      verify_ssl: $verify_ssl,
      run_inline_ig_probe: $run_ig,
      run_multi_initiator_put: $run_mi_put,
      note: "Password and session token are never included in this output."
    },
    login: { ok: true, http_code: $login_http },
    initiator_groups_inline: $ig,
    snapshots_vol_id_filter: $snap,
    access_control_records_vol_id_filter: $acr,
    volume_multi_initiator: $volume_multi_initiator,
    arrays_sample_fields: $arrays,
    forced_offline: {
      automated: false,
      note: "PUT volumes/:id online:false vs online:false+force is firmware and session dependent; validate manually on your array version."
    }
  }')

printf '%s\n' "$REPORT" | jq . >"$OUT"
echo "Wrote $OUT" >&2
