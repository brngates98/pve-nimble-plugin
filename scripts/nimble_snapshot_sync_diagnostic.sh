#!/usr/bin/env bash
# Read-only diagnostic for nimble_sync_array_snapshots: volumes vs snapshot vol_name matching,
# bulk vs per-vol GET snapshots, sample snapshot rows, and (when any snapshot exists) a probe of
# GET snapshots/:id, snapshots?id=, volumes/:id, snapshot_collections/:id — same order as the plugin
# uses to fill creation_time / last_modified for PVE snaptime.
#
# Requires: curl, jq
# Usage: ./scripts/nimble_snapshot_sync_diagnostic.sh [output.json]
#   VERIFY_SSL=1  — verify TLS (default: curl -k)
#   MAX_VOLUMES=N — cap per-volume GET snapshots?vol_id= (default 60; 0 = no cap)
#
# Prompts: Nimble API base URL, username, password (same as nimble_capacity_api_probe.sh).
#
set -euo pipefail

OUT="${1:-nimble-snapshot-sync-diagnostic-$(date -u +%Y%m%dT%H%M%SZ).json}"
MAX_VOLUMES="${MAX_VOLUMES:-60}"

CURL_OPTS=( -sS )
[[ "${VERIFY_SSL:-}" == "1" ]] || CURL_OPTS+=( -k )

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Error: missing $1" >&2; exit 1; }; }
need_cmd curl
need_cmd jq

jq_nimble_list='.data as $d |
  (if ($d | type) == "array" then $d
   elif ($d | type) == "object" and (($d.items // null) | type) == "array" then $d.items
   elif ($d | type) == "object" and (($d.data // null) | type) == "array" then $d.data
   elif ($d | type) == "object" and (($d.id // "") != "") then [$d]
   else [] end)'

api_get() {
  local path="$1" out="$2" code
  code=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$out" "$BASE/v1/$path" -H "X-Auth-Token: $TOKEN")
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

LOGIN=$(jq -n --arg u "$USERNAME" --arg p "$PASSWORD" '{data:{username:$u,password:$p}}')
HCODE=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$TMP/login.json" -X POST "$BASE/v1/tokens" \
  -H 'Content-Type: application/json' -d "$LOGIN")
[[ "$HCODE" == "200" || "$HCODE" == "201" ]] || { echo "Login failed HTTP $HCODE" >&2; cat "$TMP/login.json" >&2; exit 1; }
TOKEN=$(jq -r '.data.session_token // .session_token // empty' "$TMP/login.json")
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { echo "No session_token" >&2; exit 1; }

VCODE=$(api_get "volumes" "$TMP/volumes.json")
VOL_LIST=$(jq -c "$jq_nimble_list" "$TMP/volumes.json")
VOL_COUNT=$(jq "$jq_nimble_list | length" "$TMP/volumes.json")

# Trim volume list for per-vol GETs
if [[ "$MAX_VOLUMES" =~ ^[0-9]+$ ]] && [[ "$MAX_VOLUMES" -gt 0 ]]; then
  VOL_LIST_TRIM=$(echo "$VOL_LIST" | jq -c ".[0:$MAX_VOLUMES]")
else
  VOL_LIST_TRIM="$VOL_LIST"
fi

VOL_ROWS=$(echo "$VOL_LIST" | jq -c 'map({id, name, full_name, search_name, serial_number})')

# Bulk snapshots
BCODE=$(api_get "snapshots" "$TMP/snap_bulk.json")
BULK_SNIP="$(head -c 4000 "$TMP/snap_bulk.json" 2>/dev/null || true)"
BULK_OK_JSON=$( [[ "$BCODE" =~ ^2[0-9][0-9]$ ]] && echo true || echo false )
BULK_COUNT=0
BULK_SAMPLES='[]'
if [[ "$BCODE" =~ ^2[0-9][0-9]$ ]]; then
  BULK_COUNT=$(jq "$jq_nimble_list | length" "$TMP/snap_bulk.json")
  BULK_SAMPLES=$(jq -c "$jq_nimble_list | map({id, name, creation_time, last_modified, snap_collection_id, vol_name, vol_id, volume_name}) | .[0:5]" "$TMP/snap_bulk.json")
fi
REQUIRES_FILTER_JSON=$(echo "$BULK_SNIP" | jq -Rs 'test("SM_missing_arg")')

# Per-volume snapshot fetches
rm -f "$TMP"/pv_*.json
idx=0
while IFS= read -r row; do
  vid=$(echo "$row" | jq -r '.id // empty')
  vname=$(echo "$row" | jq -r '.name // empty')
  [[ -n "$vid" ]] || continue
  code=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$TMP/snap_one.json" -G "$BASE/v1/snapshots" \
    -H "X-Auth-Token: $TOKEN" --data-urlencode "vol_id=$vid")
  cnt=$(jq "$jq_nimble_list | length" "$TMP/snap_one.json")
  samples=$(jq -c "$jq_nimble_list | map({
    id: .id,
    name: .name,
    creation_time: .creation_time,
    last_modified: .last_modified,
    snap_collection_id: .snap_collection_id,
    vol_name: .vol_name,
    vol_id: .vol_id,
    volume_name: .volume_name
  }) | .[0:8]" "$TMP/snap_one.json")
  vol_names_distinct=$(jq -c "$jq_nimble_list | [ .[] | .vol_name // empty | select(length > 0) ] | unique" "$TMP/snap_one.json")
  jq -n \
    --arg vid "$vid" \
    --arg vname "$vname" \
    --argjson http "$(jq -n --arg c "$code" '$c|tonumber')" \
    --argjson count "$cnt" \
    --argjson samples "$samples" \
    --argjson vol_names_distinct "$vol_names_distinct" \
    '{
      volume_id: $vid,
      volume_name: $vname,
      get_http_code: $http,
      snapshot_count: $count,
      snapshot_samples: $samples,
      distinct_snapshot_vol_names_for_this_volume: $vol_names_distinct
    }' >"$TMP/pv_${idx}.json"
  idx=$((idx + 1))
done < <(echo "$VOL_LIST_TRIM" | jq -c '.[]')

if [[ "$idx" -eq 0 ]]; then
  PER_VOL='[]'
else
  PER_VOL=$(jq -s '.' "$TMP"/pv_*.json)
fi

# Probe detail endpoints for one snapshot id (verify where creation_time appears — matches plugin hydration order).
fields_from_nimble_json() {
  local f="$1"
  jq -c '
    if (.data | type) == "object" and (.data.id != null or .data.creation_time != null or .data.name != null) then
      .data | {creation_time, last_modified, snap_collection_id, name}
    elif (.data | type) == "array" and (.data | length) > 0 then
      .data[0] | {creation_time, last_modified, snap_collection_id, name}
    else
      {note: "unexpected or error body", raw_type: (.data | type)}
    end
  ' "$f" 2>/dev/null || echo '{"note":"jq parse failed"}'
}

wrap_probe() {
  local code="$1" file="$2"
  jq -n --arg c "$code" --argjson inner "$(fields_from_nimble_json "$file")" \
    '{http: ($c|tonumber)} + $inner'
}

LIST_ROW_FOR_PROBE=$(echo "$PER_VOL" | jq -c '[.[].snapshot_samples[]?] | map(select(.id != null and (.id|tostring|length) > 0)) | .[0] // null')
PROBE_ID=$(echo "$LIST_ROW_FOR_PROBE" | jq -r 'if . == null then empty else .id end')
if [[ -z "$PROBE_ID" ]] && [[ "$BULK_OK_JSON" == "true" ]] && [[ "$BULK_COUNT" -gt 0 ]]; then
  LIST_ROW_FOR_PROBE=$(jq -c "$jq_nimble_list | map(select(.id != null)) | .[0] // null" "$TMP/snap_bulk.json")
  PROBE_ID=$(echo "$LIST_ROW_FOR_PROBE" | jq -r 'if . == null then empty else .id end')
fi

TIME_PROBE_JSON='{"skipped":"no snapshot id available for time probe"}'
if [[ -n "$PROBE_ID" ]]; then
  SNAP_P=$(api_get "snapshots/${PROBE_ID}" "$TMP/probe_snap_path.json")
  SNAP_Q=$(curl "${CURL_OPTS[@]}" -w '%{http_code}' -o "$TMP/probe_snap_q.json" -G "$BASE/v1/snapshots" \
    -H "X-Auth-Token: $TOKEN" --data-urlencode "id=$PROBE_ID")
  VOL_P=$(api_get "volumes/${PROBE_ID}" "$TMP/probe_vol.json")

  SCID=$(echo "$LIST_ROW_FOR_PROBE" | jq -r '.snap_collection_id // empty')
  if [[ -z "$SCID" ]]; then
    SCID=$(jq -r '
      if (.data | type) == "object" then .data.snap_collection_id // empty
      elif (.data | type) == "array" and (.data | length) > 0 then .data[0].snap_collection_id // empty
      else empty end
    ' "$TMP/probe_snap_path.json" 2>/dev/null)
    SCID=${SCID:-}
  fi

  COLL_JSON='null'
  if [[ -n "$SCID" ]]; then
    COLL_C=$(api_get "snapshot_collections/${SCID}" "$TMP/probe_coll.json")
    COLL_JSON=$(wrap_probe "$COLL_C" "$TMP/probe_coll.json")
  fi

  TIME_PROBE_JSON=$(jq -n \
    --arg sid "$PROBE_ID" \
    --argjson list_row "${LIST_ROW_FOR_PROBE:-null}" \
    --argjson get_snapshots_path "$(wrap_probe "$SNAP_P" "$TMP/probe_snap_path.json")" \
    --argjson get_snapshots_query "$(wrap_probe "$SNAP_Q" "$TMP/probe_snap_q.json")" \
    --argjson get_volumes_path "$(wrap_probe "$VOL_P" "$TMP/probe_vol.json")" \
    --argjson get_snapshot_collection "$COLL_JSON" \
    --arg scid "${SCID:-}" \
    '{
      chosen_snapshot_id: $sid,
      list_row_from_vol_filter: $list_row,
      snap_collection_id_used: (if ($scid|length) > 0 then $scid else null end),
      GET_snapshots_id_path: $get_snapshots_path,
      GET_snapshots_id_query: $get_snapshots_query,
      GET_volumes_id_path: $get_volumes_path,
      GET_snapshot_collection_id_path: $get_snapshot_collection,
      note: "If list_row has null creation_time but GET_volumes_id_path or GET_snapshots_id_path shows creation_time, the plugin can display Nimble time in PVE after hydration."
    }')
fi

# Analysis: volume name keys vs snapshot vol_name (from per-volume samples + all snaps in those responses)
ANALYSIS=$(jq -n \
  --argjson volrows "$VOL_ROWS" \
  --argjson pervol "$PER_VOL" \
  '{
    volume_name_strings: [ $volrows[] | .name // empty | select(length > 0) ],
    volume_full_names: [ $volrows[] | .full_name // empty | select(length > 0) ],
    volume_search_names: [ $volrows[] | .search_name // empty | select(length > 0) ],
    snapshot_vol_names_seen: (
      [ $pervol[] | .distinct_snapshot_vol_names_for_this_volume[]? ] | unique
    ),
    snapshot_volume_names_seen: (
      [ $pervol[] | .snapshot_samples[]? | .volume_name // empty | select(length > 0) ] | unique
    )
  } | . as $b |
  ($b.volume_name_strings | unique) as $vn |
  ($b.snapshot_vol_names_seen) as $sn |
  {
    volume_name_strings: $vn,
    snapshot_vol_name_values_distinct: $sn,
    snapshot_vol_names_that_exact_match_a_volume_name: [ $sn[] | select(. as $s | $vn | index($s) != null) ],
    snapshot_vol_names_that_do_not_match_any_volume_name: [ $sn[] | select(. as $s | $vn | index($s) == null) ],
    note: "Plugin nimble_sync_array_snapshots matches snapshot rows to volumes[].name (API): uses vol_name/volume_name when present, else the volume from GET snapshots?vol_id= context (or vol_id map on bulk lists). Sparse vol_name => distinct_snapshot_vol_names_for_this_volume may be empty even when sync works."
  }')

REPORT=$(jq -n \
  --arg base "$BASE" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg script "nimble_snapshot_sync_diagnostic.sh" \
  --arg outfile "$OUT" \
  --argjson max_volumes "$MAX_VOLUMES" \
  --argjson vol_http "$(jq -n --arg c "$VCODE" '$c|tonumber')" \
  --argjson vol_count "$VOL_COUNT" \
  --argjson vol_rows "$VOL_ROWS" \
  --argjson bulk_http "$(jq -n --arg c "$BCODE" '$c|tonumber')" \
  --argjson bulk_ok "$BULK_OK_JSON" \
  --argjson bulk_count "$BULK_COUNT" \
  --argjson bulk_samples "$BULK_SAMPLES" \
  --argjson requires_filter "$REQUIRES_FILTER_JSON" \
  --arg bulk_snip "$BULK_SNIP" \
  --argjson per_volume "$PER_VOL" \
  --argjson analysis "$ANALYSIS" \
  --argjson snapshot_time_detail_probe "$TIME_PROBE_JSON" \
  '{
    meta: {
      nimble_api_base: $base,
      generated_utc: $generated,
      script: $script,
      output_file: $outfile,
      max_volumes_per_vol_get: $max_volumes,
      note: "Read-only. Redact this file before posting publicly if needed; no password or token included."
    },
    volumes: {
      get_http_code: $vol_http,
      count: $vol_count,
      rows: $vol_rows
    },
    snapshots_bulk: {
      get_http_code: $bulk_http,
      ok: $bulk_ok,
      count: $bulk_count,
      first_rows_sample: $bulk_samples,
      error_or_body_snippet: (if $bulk_ok then null else $bulk_snip end),
      firmware_expects_query_filter: $requires_filter
    },
    snapshots_per_volume: $per_volume,
    snapshot_time_detail_probe: $snapshot_time_detail_probe,
    sync_vol_name_analysis: $analysis
  }')

printf '%s\n' "$REPORT" | jq . >"$OUT"
echo "Wrote $OUT" >&2
echo "Per-volume GETs: $idx volume(s). Share JSON (redact hostnames if you want)." >&2
