#!/bin/bash
# =========================================================================
# Device Probe Library
# =========================================================================

is_device_accessible() {
    local dev=$1
    # 1. Block device exists
    [ -b "/dev/$dev" ] || return 1
    # 2. Sysfs node exists
    [ -e "/sys/class/block/$dev/device" ] || return 1
    # 3. smartctl can communicate
    smartctl -i "/dev/$dev" >/dev/null 2>&1 || return 1
    return 0 
}
