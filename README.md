# pve-usb-passthrough-watchdog

A small watchdog for Proxmox VE hosts that re-attaches a USB passthrough device to a running VM when the passthrough silently breaks.

Written for a Zigbee coordinator (dresden elektronik ConBee II) passed through to a Home Assistant OS VM, but it works for any `usb-host` passthrough device: Z-Wave sticks, SDRs, UPS cables, serial adapters.

## The problem

The VM gets the USB device via `qm set <vmid> -usb0 host=<vendor>:<product>`. Normally QEMU follows the device when it disconnects and reconnects on the host. Sometimes it does not:

- The device re-enumerates on the host, here twice within 4 seconds. Causes include a USB reset, a flaky hub or the stick's own firmware watchdog.
- `qm monitor <vmid>` → `info usb` **still lists the device** as attached to the VM.
- The guest no longer has it: `/dev/serial/by-id/...` is gone and ZHA, Zigbee2MQTT or Z-Wave JS stop working.
- On the host, the kernel driver (`cdc_acm` for most serial sticks) has claimed the device and `/dev/ttyACM0` exists **on the host**.

Nothing recovers this automatically. In our case Zigbee stayed dead for three days until someone noticed. The ConBee then started resetting itself roughly every hour, because its firmware watchdog was no longer fed by any application. That made the host log look like a hardware problem.

## How the watchdog detects it

A device that is passed through correctly has **all of its USB interfaces bound to `usbfs`**, the driver QEMU uses to talk to it:

```
$ readlink /sys/bus/usb/devices/1-1.3:1.0/driver
../../../../../../bus/usb/drivers/usbfs
```

If any interface is bound to a different driver, for example `cdc_acm`, or to none, the host owns the device and the VM does not.

The watchdog checks this every 15 seconds. If the device stays host-owned for 60 seconds, it removes the device from the VM and adds it back through the QEMU monitor:

```
qm monitor <vmid>
  device_del usb0
  device_add usb-host,bus=xhci.0,port=1,vendorid=0x1cf1,productid=0x0030,id=usb0
```

The `device_add` arguments are not hard-coded. They are taken from `qm showcmd <vmid>`, so the device comes back exactly as Proxmox defined it at VM start. The VM does not need to be rebooted.

## Installation

On the Proxmox VE host, as root:

```bash
install -m 755 pve-usb-passthrough-watchdog.sh /usr/local/sbin/
install -m 644 pve-usb-passthrough-watchdog.conf /etc/default/pve-usb-passthrough-watchdog
install -m 644 pve-usb-passthrough-watchdog.service /etc/systemd/system/
# adjust VMID, USB_ID and DEVICE_ID
nano /etc/default/pve-usb-passthrough-watchdog
systemctl daemon-reload
systemctl enable --now pve-usb-passthrough-watchdog
```

Find the values with:

```bash
lsusb                      # USB_ID, e.g. 1cf1:0030
qm config <vmid> | grep usb   # DEVICE_ID, e.g. usb0: host=1cf1:0030
```

## Configuration

`/etc/default/pve-usb-passthrough-watchdog`:

| Variable | Default | Meaning |
|---|---|---|
| `VMID` | – | guest that owns the device |
| `USB_ID` | – | `vendor:product` as shown by `lsusb` |
| `DEVICE_ID` | `usb0` | key of the passthrough in `qm config` |
| `INTERVAL` | `15` | seconds between checks |
| `GRACE` | `60` | seconds the device may stay host-owned before acting (QEMU often reclaims it by itself within a few seconds) |
| `COOLDOWN` | `300` | seconds to wait after a re-attach |

## Usage

```bash
# one-off check: prints passthrough / host:<driver> / absent / vm-stopped
set -a; . /etc/default/pve-usb-passthrough-watchdog; set +a
/usr/local/sbin/pve-usb-passthrough-watchdog.sh --check

# what the service did
journalctl -u pve-usb-passthrough-watchdog
```

Typical log of a recovery:

```
device is owned by the host (host:cdc_acm), waiting 60s for QEMU to reclaim it
re-attaching 1cf1:0030 to VM 100 (usb-host,bus=xhci.0,port=1,vendorid=0x1cf1,productid=0x0030,id=usb0)
state after re-attach: passthrough
```

## Testing it

You can reproduce the failure by taking the device away from the VM without telling Proxmox:

```bash
echo "device_del usb0" | qm monitor <vmid>
```

The host driver claims the device within seconds, `--check` reports `host:cdc_acm`, and the watchdog re-attaches it after `GRACE` seconds. With Home Assistant's ZHA (zigpy/deCONZ) the integration reconnected by itself without a reload.

## Limitations

- One device per service instance. For several devices, copy the unit as a template unit with one config file per device.
- If several attached devices share the same `vendor:product`, the first one found in sysfs is checked. Pass through by port (`host=1-1.3`) in that case and adapt `find_device`.
- The watchdog only repairs the passthrough. It does not explain why the device disconnects in the first place. For Zigbee sticks, the usual advice still applies: use a USB 2.0 port and an extension cable, keep the stick away from USB 3 devices and SSDs, and avoid unpowered hubs.

Tested with Proxmox VE 8.4 (QEMU 9.2), HAOS VM with `q35` and `qemu-xhci`.

## License

MIT
