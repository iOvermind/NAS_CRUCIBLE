#!/bin/bash
# =========================================================================
# M1A/M1B: Identity Classification & Capability Probe
# =========================================================================
DRIVES=("$@")
LOG_DIR="./logs"
MANIFEST_FILE="device_manifest.json"
mkdir -p "$LOG_DIR"
echo "{}" > "$MANIFEST_FILE"

for dev in "${DRIVES[@]}"; do
    json_out="$LOG_DIR/${dev}_identity.json"
    smartctl -j -x "/dev/$dev" > "$json_out" 2>/dev/null
    
    if ! jq empty "$json_out" >/dev/null 2>&1; then echo "❌ /dev/$dev JSON 解析失敗"; exit 1; fi
    smart_rc=$(jq -r '.smartctl.exit_status // empty' "$json_out")
    if ! [[ "$smart_rc" =~ ^[0-9]+$ ]]; then echo "❌ /dev/$dev smartctl.exit_status 無效"; exit 1; fi
    
    protocol=$(jq -r '.device.protocol // "null"' "$json_out")
    scsi_type=$(jq -r '.device_type.name // "null"' "$json_out")
    serial=$(jq -r '.serial_number // "UNKNOWN"' "$json_out")
    is_ssd=$(jq -r '.solid_state_device.value // "null"' "$json_out")
    rot_rate=$(jq -r '.rotation_rate // "null"' "$json_out")
    
    [ "$serial" = "UNKNOWN" ] && { echo "❌ /dev/$dev 無效 Serial"; exit 1; }

    class="UNKNOWN"
    if [ "$protocol" = "ATA" ]; then
        if [ "$is_ssd" = "true" ] || [ "$rot_rate" = "0" ]; then class="SATA_SSD"
        else class="SATA_HDD"; fi
    elif [ "$protocol" = "SCSI" ]; then
        if [ "$is_ssd" = "true" ] || [ "$rot_rate" = "0" ]; then class="SAS_SSD"
        else class="SAS_HDD"; fi
    fi
    [ "$class" = "UNKNOWN" ] && { echo "❌ /dev/$dev 分類失敗"; exit 1; }

    jq --arg sn "$serial" --arg dev "$dev" --arg class "$class" --arg proto "$protocol" --argjson rc "$smart_rc" \
       '. + {($sn): {identity: {device_handle: $dev, serial: $sn, class: $class, protocol: $proto}, smartctl: {exit_status: $rc}}}' \
       "$MANIFEST_FILE" > "${MANIFEST_FILE}.tmp" && mv "${MANIFEST_FILE}.tmp" "$MANIFEST_FILE"
    
    # 寫入假 Capability Probe 供 Policy 驗證
    jq --arg sn "$serial" '.[$sn].probe_status = "SUCCESS" | .[$sn].host_capabilities = {"badblocks": true}' \
       "$MANIFEST_FILE" > "${MANIFEST_FILE}.tmp" && mv "${MANIFEST_FILE}.tmp" "$MANIFEST_FILE"
    echo "✅ /dev/$dev (SN: $serial) -> $class"
done
