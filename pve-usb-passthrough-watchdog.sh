#!/bin/bash
# pve-usb-passthrough-watchdog
#
# Re-attaches a USB device to a running Proxmox VE guest when the passthrough
# silently breaks after the device re-enumerated on the host.
#
# Failure mode this fixes: the device disconnects and reconnects on the host
# (USB reset, firmware watchdog, flaky hub). QEMU's `info usb` still lists the
# passthrough device, but the guest never sees it again and the host kernel
# driver (e.g. cdc_acm for Zigbee/Z-Wave sticks) claims it instead. Healthy
# passthrough means every interface of the device is bound to `usbfs`.
#
# Configuration via environment (see pve-usb-passthrough-watchdog.conf):
#   VMID      guest ID                                   (required)
#   USB_ID    vendor:product, e.g. 1cf1:0030             (required)
#   DEVICE_ID QEMU device id of the passthrough, e.g. usb0 (default: usb0)
#   INTERVAL  seconds between checks                     (default: 15)
#   GRACE     seconds the device may be host-owned before acting (default: 60)
#   COOLDOWN  seconds to wait after a re-attach          (default: 300)
#
# Usage: pve-usb-passthrough-watchdog.sh [--check]
#   --check   run one check, print the state, exit 0 (ok) or 1 (broken)

set -u

VMID=${VMID:?VMID not set}
USB_ID=${USB_ID:?USB_ID not set}
DEVICE_ID=${DEVICE_ID:-usb0}
INTERVAL=${INTERVAL:-15}
GRACE=${GRACE:-60}
COOLDOWN=${COOLDOWN:-300}

VENDOR=${USB_ID%%:*}
PRODUCT=${USB_ID##*:}

log() { echo "$*"; }

# Prints the sysfs name (e.g. 1-1.3) of the first device matching USB_ID.
find_device() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] || continue
        if [ "$(cat "$d/idVendor")" = "$VENDOR" ] && [ "$(cat "$d/idProduct")" = "$PRODUCT" ]; then
            basename "$d"
            return 0
        fi
    done
    return 1
}

# Prints "passthrough", "host:<driver>", "absent" or "vm-stopped".
device_state() {
    local dev iface drv
    if ! qm status "$VMID" 2>/dev/null | grep -q 'status: running'; then
        echo vm-stopped
        return
    fi
    dev=$(find_device) || { echo absent; return; }
    for iface in /sys/bus/usb/devices/"$dev":*; do
        [ -e "$iface" ] || continue
        if [ -e "$iface/driver" ]; then
            drv=$(basename "$(readlink -f "$iface/driver")")
        else
            drv=none
        fi
        if [ "$drv" != usbfs ]; then
            echo "host:$drv"
            return
        fi
    done
    echo passthrough
}

monitor() {
    printf '%s\n' "$1" | qm monitor "$VMID" 2>&1
}

# The device spec is taken from the VM's generated QEMU command line, so the
# re-attached device is identical to the one Proxmox created at VM start.
device_spec() {
    qm showcmd "$VMID" 2>/dev/null \
        | grep -o "usb-host,[^' ]*id=$DEVICE_ID\b[^' ]*" \
        | head -n1
}

reattach() {
    local spec i
    spec=$(device_spec)
    if [ -z "$spec" ]; then
        log "ERROR: no usb-host device with id=$DEVICE_ID in the QEMU command line of VM $VMID"
        return 1
    fi
    log "re-attaching $USB_ID to VM $VMID ($spec)"
    monitor "device_del $DEVICE_ID" >/dev/null
    for i in $(seq 1 20); do
        monitor "info usb" | grep -q "ID: $DEVICE_ID\$" || break
        sleep 0.5
    done
    monitor "device_add $spec" >/dev/null
    sleep 3
    log "state after re-attach: $(device_state)"
}

if [ "${1:-}" = "--check" ]; then
    state=$(device_state)
    echo "$state"
    [ "$state" = passthrough ] || [ "$state" = vm-stopped ]
    exit
fi

log "watching $USB_ID for VM $VMID (device $DEVICE_ID), grace ${GRACE}s"
broken_since=0
while true; do
    state=$(device_state)
    case "$state" in
        host:*)
            now=$(date +%s)
            if [ "$broken_since" -eq 0 ]; then
                broken_since=$now
                log "device is owned by the host ($state), waiting ${GRACE}s for QEMU to reclaim it"
            elif [ $((now - broken_since)) -ge "$GRACE" ]; then
                reattach
                broken_since=0
                sleep "$COOLDOWN"
                continue
            fi
            ;;
        *)
            if [ "$broken_since" -ne 0 ]; then
                log "device recovered by itself ($state)"
            fi
            broken_since=0
            ;;
    esac
    sleep "$INTERVAL"
done
