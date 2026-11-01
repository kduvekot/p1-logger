#!/usr/bin/env bash
# install.sh -- idempotent installer for p1-logger on Raspberry Pi OS.
#
# Usage (no git clone required):
#     curl -LsSf https://raw.githubusercontent.com/kduvekot/p1-logger/main/install.sh \
#         | sudo bash
#
# Pin to a tag / branch / commit, with site-specific overrides:
#     curl ... | sudo bash -s -- --ref v0.1.0 \
#         --device /dev/p1 --baud 115200 --remote nas:share/host/p1 --yes
#
# From a local checkout (interactive prompts if stdin is a TTY):
#     sudo ./install.sh
#
# Safe to re-run: every step checks for existing state before acting, so this
# is also the upgrade path -- point it at a newer ref and re-run.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REPO="${REPO:-kduvekot/p1-logger}"
REF="${REF:-main}"

# DSMR 4/5 meters: 115200 8N1. (DSMR 2.2/3 use 9600 7E1 -- not supported.)
DEFAULT_P1_DEVICE=/dev/ttyUSB0
DEFAULT_P1_BAUD=115200
DEFAULT_P1_REMOTE=

CONFIG=/etc/p1-logger/p1-logger.conf

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
CLI_DEVICE=""
CLI_BAUD=""
CLI_REMOTE=""
ASSUME_YES=false

usage() {
    cat <<USAGE
Usage: install.sh [options]

Options (all optional):
  --ref <git-ref>        git ref to fetch files from (default: main)
  --repo <owner/repo>    repo on GitHub (default: kduvekot/p1-logger)

  --device <path>        P1 serial device (default: /dev/ttyUSB0); a udev
                         symlink such as /dev/p1 is recommended
  --baud <int>           baud rate, 8N1 (default: 115200)
  --remote <rclone>      rclone remote for sync, e.g. nas:share/host/p1
                         (default: empty = sync disabled)

  --yes                  don't prompt; use CLI/existing-conf/defaults
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref)       REF="$2"; shift 2 ;;
        --ref=*)     REF="${1#--ref=}"; shift ;;
        --repo)      REPO="$2"; shift 2 ;;
        --repo=*)    REPO="${1#--repo=}"; shift ;;
        --device)    CLI_DEVICE="$2"; shift 2 ;;
        --device=*)  CLI_DEVICE="${1#--device=}"; shift ;;
        --baud)      CLI_BAUD="$2"; shift 2 ;;
        --baud=*)    CLI_BAUD="${1#--baud=}"; shift ;;
        --remote)    CLI_REMOTE="$2"; shift 2 ;;
        --remote=*)  CLI_REMOTE="${1#--remote=}"; shift ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

BASE_URL="https://raw.githubusercontent.com/${REPO}/${REF}"

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

if [[ ${EUID} -ne 0 ]]; then
    echo "install.sh must be run as root (e.g. piped into 'sudo bash')" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve configuration values
#   precedence: CLI flag > existing /etc/p1-logger/p1-logger.conf > default
# ---------------------------------------------------------------------------
P1_DEVICE="$DEFAULT_P1_DEVICE"
P1_BAUD="$DEFAULT_P1_BAUD"
P1_REMOTE="$DEFAULT_P1_REMOTE"

CONFIG_EXISTS=false
if [[ -f "$CONFIG" ]]; then
    CONFIG_EXISTS=true
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

[[ -n "$CLI_DEVICE" ]] && P1_DEVICE="$CLI_DEVICE"
[[ -n "$CLI_BAUD"   ]] && P1_BAUD="$CLI_BAUD"
[[ -n "$CLI_REMOTE" ]] && P1_REMOTE="$CLI_REMOTE"

prompt_if_unset() {
    local cli="$1" varname="$2" prompt="$3"
    [[ -n "$cli" ]] && return 0
    local current="${!varname}"
    local answer
    read -r -p "$prompt [$current]: " answer || return 0
    [[ -n "$answer" ]] && printf -v "$varname" '%s' "$answer"
}

if [[ "$ASSUME_YES" == false && -t 0 && "$CONFIG_EXISTS" == false ]]; then
    say "Interactive config (press Enter to accept each default)"
    echo
    prompt_if_unset "$CLI_DEVICE" P1_DEVICE "P1 serial device"
    prompt_if_unset "$CLI_BAUD"   P1_BAUD   "Baud rate (8N1)"
    prompt_if_unset "$CLI_REMOTE" P1_REMOTE "rclone remote for sync (empty to skip)"
    echo
elif [[ "$CONFIG_EXISTS" == true ]]; then
    say "Existing $CONFIG found; keeping its values (CLI flags still win)"
fi

say "Resolved settings:"
printf '    %-12s %s\n' \
    "P1_DEVICE" "$P1_DEVICE" \
    "P1_BAUD"   "$P1_BAUD" \
    "P1_REMOTE" "${P1_REMOTE:-(sync disabled)}"

# ---------------------------------------------------------------------------
# Staging: either copy from the local checkout, or fetch from GitHub raw.
# ---------------------------------------------------------------------------
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

fetch() {
    local rel="$1" dst="${STAGE}/${1}"
    if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/${rel}" ]]; then
        cp "${SCRIPT_DIR}/${rel}" "${dst}"
    else
        printf '    curl %s\n' "${BASE_URL}/${rel}"
        curl -LsSf --retry 3 --retry-delay 2 "${BASE_URL}/${rel}" -o "${dst}"
    fi
}

if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/p1-logger.py" ]]; then
    say "Using local files from ${SCRIPT_DIR}"
else
    say "Fetching files from ${BASE_URL}"
fi

fetch p1-logger.py
fetch p1-logger.service
fetch p1-sync.service
fetch p1-sync.timer

# The logger unit ships bound to dev-ttyUSB0.device; point BindsTo/After/
# WantedBy at the configured device (a udev symlink such as /dev/p1 gets its
# own dev-p1.device unit).
devunit="$(systemd-escape --path --suffix=device "$P1_DEVICE")"
sed -i -E "s/^(BindsTo|After|WantedBy)=dev-[^ ]+\.device$/\1=${devunit}/" \
    "${STAGE}/p1-logger.service"

# ---------------------------------------------------------------------------
# apt prerequisites
# ---------------------------------------------------------------------------
say "Installing apt prerequisites (python3-serial, rclone, curl, ca-certificates)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3 python3-serial rclone curl ca-certificates

# ---------------------------------------------------------------------------
# p1logger system user
# ---------------------------------------------------------------------------
if ! getent passwd p1logger >/dev/null; then
    say "Creating p1logger system user"
    useradd --system \
        --home-dir /var/lib/p1-logger \
        --create-home \
        --shell /usr/sbin/nologin \
        --groups dialout \
        --comment "P1 smart-meter logger" \
        p1logger
else
    say "p1logger user already exists; ensuring dialout membership"
    usermod -aG dialout p1logger
    install -d -o p1logger -g p1logger -m 0755 /var/lib/p1-logger
fi

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
say "Installing logger script to /opt/p1-logger/"
install -d -o root -g root -m 0755 /opt/p1-logger
install -o root -g p1logger -m 0644 \
    "${STAGE}/p1-logger.py" /opt/p1-logger/p1-logger.py

say "Installing systemd units to /etc/systemd/system/"
for u in p1-logger.service p1-sync.service p1-sync.timer; do
    install -o root -g root -m 0644 "${STAGE}/${u}" "/etc/systemd/system/${u}"
done

say "Writing $CONFIG"
install -d -o root -g p1logger -m 0750 /etc/p1-logger
TMPCONF="$(mktemp)"
cat > "$TMPCONF" <<CONF
# /etc/p1-logger/p1-logger.conf
#
# Site-specific configuration for p1-logger.
# Generated by install.sh; safe to hand-edit (then 'systemctl restart
# p1-logger.service' to pick up changes).

# Serial device + baud for the P1 cable (DSMR 4/5: 115200 8N1).
P1_DEVICE=${P1_DEVICE}
P1_BAUD=${P1_BAUD}

# rclone remote for off-box sync. Format: <remote>:<path>
# Leave empty to disable sync (the timer will then no-op every tick).
P1_REMOTE=${P1_REMOTE}
CONF
install -o root -g p1logger -m 0640 "$TMPCONF" "$CONFIG"
rm -f "$TMPCONF"

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
say "Reloading systemd"
systemctl daemon-reload

say "Checking that python3 can import pyserial"
if ! /usr/bin/python3 /opt/p1-logger/p1-logger.py --help >/dev/null; then
    warn "p1-logger.py --help failed -- check python3-serial install"
fi

cat <<NEXT

==> Install complete.

Resolved config written to $CONFIG:
  device ${P1_DEVICE} @ ${P1_BAUD} baud 8N1 (systemd unit ${devunit})
  rclone remote: ${P1_REMOTE:-(unset -- sync disabled)}

Next steps:

  # Start the logger (it runs whenever the P1 cable is plugged in)
  sudo systemctl enable --now p1-logger.service

  # Off-box sync (expects /etc/p1-logger/rclone.conf, mode 0640 root:p1logger):
  sudo systemctl enable --now p1-sync.timer

Watching logs:
  journalctl -u p1-logger.service -f
  journalctl -u p1-sync.service -f
NEXT
