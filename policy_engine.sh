#!/bin/bash
# =========================================================================
# M1C: Preflight Policy Engine
# =========================================================================
MANIFEST_FILE="device_manifest.json"
DECISIONS_FILE="policy_decisions.json"
POLICY_DIR="./policies"
echo "{}" > "$DECISIONS_FILE"

while IFS= read -r sn; do
    class=$(jq -r --arg sn "$sn" '.[$sn].identity.class // "UNKNOWN"' "$MANIFEST_FILE")
    probe=$(jq -r --arg sn "$sn" '.[$sn].probe_status // "UNKNOWN"' "$MANIFEST_FILE")
    
    decision="ALLOW"
    reasons="[]"
    pol_name="NONE"
    pol_ver="N/A"
    prof="NONE"

    if [ "$class" == "UNKNOWN" ]; then decision="BLOCK"; reasons='[{"code":"UNKNOWN_CLASS"}]'
    elif [ "$probe" != "SUCCESS" ]; then decision="BLOCK"; reasons='[{"code":"PROBE_FAILED"}]'
    else
        pfile="$POLICY_DIR/$(echo "$class" | tr '[:upper:]' '[:lower:]').json"
        if [ ! -f "$pfile" ]; then decision="BLOCK"; reasons='[{"code":"POLICY_NOT_FOUND"}]'
        else
            pol_name=$(jq -r '.name' "$pfile")
            pol_ver=$(jq -r '.version' "$pfile")
            prof=$(jq -r '.execution_profile' "$pfile")
        fi
    fi

    jq --arg sn "$sn" --arg dec "$decision" --arg pn "$pol_name" --arg pv "$pol_ver" --arg prof "$prof" --argjson rsn "$reasons" \
       '. + {($sn): {policy: {name: $pn, version: $pv, execution_profile: $prof}, decision: $dec, reasons: $rsn}}' \
       "$DECISIONS_FILE" > "${DECISIONS_FILE}.tmp" && mv "${DECISIONS_FILE}.tmp" "$DECISIONS_FILE"
    echo "⚖️  $sn -> $decision (Profile: $prof)"
done < <(jq -r 'keys[]' "$MANIFEST_FILE")
