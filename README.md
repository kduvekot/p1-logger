# p1-logger

Raw capture of a Dutch/Belgian smart meter's **P1 port** (DSMR 4/5) on a
Raspberry Pi, with off-box sync via rclone. Runs on anything Raspberry Pi OS
supports, down to a Pi 1 (ARMv6).

The logger stores **every byte received, verbatim**: no parsing, no CRC
check, no timestamps added. Telegrams (`/...` to `!CRC`) are byte-exact
copies of what the meter sent, corrupted ones included; DSMR 5 telegrams
carry their own timestamp (`0-0:1.0.0`). Parsing happens later, from the
files.

Companion to [jeenode-listener](https://github.com/kduvekot/jeenode-listener)
(RF12/JeeLink logging), same layout and conventions.

## Quick install

```sh
curl -LsSf https://raw.githubusercontent.com/kduvekot/p1-logger/main/install.sh \
    | sudo bash -s -- --device /dev/p1 --remote nas:share/host/p1 --yes
sudo systemctl enable --now p1-logger.service p1-sync.timer
```

`install.sh --help` lists the options; re-running it is the upgrade path.

## Architecture

| unit                         | job                                        | network? |
| ---------------------------- | ------------------------------------------ | -------- |
| `p1-logger.service`          | read the P1 port, append raw bytes         | **no**   |
| `p1-sync.timer` / `.service` | every 60 s, `rclone copy` data → remote    | yes      |

The logger is network-free, so LAN or NAS trouble cannot affect capture. The
sync uses `rclone copy` (not `sync`): the remote is an append-only mirror.

The logger hands every chunk read to a list of sinks; the raw file sink is
the only one today. Live re-exposure (e.g. serial over TCP for Home
Assistant's DSMR integration) can be added as another sink without touching
the raw capture, keeping one reader per port.

## Files

```
/opt/p1-logger/p1-logger.py
/etc/p1-logger/p1-logger.conf        P1_DEVICE, P1_BAUD, P1_REMOTE
/etc/p1-logger/rclone.conf           rclone remote (0640 root:p1logger)
/var/lib/p1-logger/data/YYYY/YYYYMMDD/HH.txt
```

Data files are hourly (UTC) rather than daily: a DSMR 5 meter sends ~1 KB/s
(~90 MB a day) and `rclone copy` re-uploads a changed file whole on every
tick. A file switches only at a telegram start, so a telegram is never split
across two files. Every chunk is appended with open/write/close, so nothing
is buffered on crash.

## Serial settings

DSMR 4 and 5: 115200 baud, 8N1. The P1 data line is inverted; common USB P1
cables (FTDI-based) invert in the cable. Older DSMR 2.2/3 meters (9600 7E1)
are not supported.

## Several FTDI adapters on one Pi

Two FT232R adapters share VID:PID `0403:6001`, so `/dev/ttyUSB*` numbering is
not stable. Pin each by serial number (`udevadm info -a /dev/ttyUSB0 | grep
serial`):

```udev
# /etc/udev/rules.d/10-sensors.rules
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", ATTRS{serial}=="<serial>", SYMLINK+="p1"
```

and install with `--device /dev/p1`; the installer binds the unit to
`dev-p1.device`, so the logger starts and stops with the cable.

## Watching

```sh
journalctl -u p1-logger.service -f
journalctl -u p1-sync.service -f
ls -l /var/lib/p1-logger/data/$(date -u +%Y/%Y%m%d)/
```
