#!/usr/bin/env bash
#
# FT-891 DigiPi CAT Setup
# Installs a stable /dev/ttyFT891 alias and a systemd rigctld service.
#
set -Eeuo pipefail

RULE_FILE="/etc/udev/rules.d/99-ft891.rules"
SERVICE_FILE="/etc/systemd/system/rigctld.service"
ALIAS="/dev/ttyFT891"
BAUD="38400"
PORT="4532"
RIG_MODEL="1036"
USB_VENDOR="10c4"
USB_PRODUCT="ea70"
USB_INTERFACE="00"

INITIAL_ROOT_RO=0
RESTORE_ROOT_RO=0

log()  { printf '\n[FT-891 setup] %s\n' "$*"; }
warn() { printf '\n[WARNING] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

restore_root_mode() {
    if [[ "$RESTORE_ROOT_RO" -eq 1 ]]; then
        log "Restoring root filesystem to read-only mode..."
        mount -o remount,ro / || warn "Could not restore read-only mode. Check root mount status."
    fi
}
trap restore_root_mode EXIT

if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Run this script as root or install sudo."
    exec sudo -E bash "$0" "$@"
fi

command -v rigctld >/dev/null 2>&1 || die "rigctld was not found. Install DigiPi's Hamlib package first."
command -v rigctl  >/dev/null 2>&1 || die "rigctl was not found. Install DigiPi's Hamlib package first."
command -v udevadm >/dev/null 2>&1 || die "udevadm was not found."

ROOT_OPTIONS="$(findmnt -n -o OPTIONS / 2>/dev/null || true)"
if [[ ",${ROOT_OPTIONS}," == *,ro,* ]]; then
    INITIAL_ROOT_RO=1
    log "Root filesystem is read-only; temporarily remounting it read/write."
    if command -v remount >/dev/null 2>&1; then
        remount
    elif [[ -x /usr/local/bin/remount ]]; then
        /usr/local/bin/remount
    else
        mount -o remount,rw / || die "Could not remount / read/write."
    fi
    ROOT_OPTIONS="$(findmnt -n -o OPTIONS / 2>/dev/null || true)"
    [[ ",${ROOT_OPTIONS}," == *,rw,* ]] || die "Root filesystem is still not writable."
    RESTORE_ROOT_RO=1
fi

log "Searching for the FT-891 CP2105 serial interface..."
matches=()
for devpath in /dev/ttyUSB*; do
    [[ -e "$devpath" ]] || continue
    props="$(udevadm info --query=property --name="$devpath" 2>/dev/null || true)"
    grep -qx "ID_VENDOR_ID=${USB_VENDOR}" <<<"$props" || continue
    grep -qx "ID_MODEL_ID=${USB_PRODUCT}" <<<"$props" || continue
    grep -qx "ID_USB_INTERFACE_NUM=${USB_INTERFACE}" <<<"$props" || continue
    serial="$(sed -n 's/^ID_SERIAL_SHORT=//p' <<<"$props" | head -n1)"
    [[ -n "$serial" ]] || continue
    matches+=("${devpath}|${serial}")
done

if [[ "${#matches[@]}" -eq 0 ]]; then
    die "No matching FT-891 CP2105 interface found (USB ${USB_VENDOR}:${USB_PRODUCT}, interface ${USB_INTERFACE}). Check the USB cable/radio and try again."
fi
if [[ "${#matches[@]}" -gt 1 ]]; then
    printf '%s\n' "${matches[@]}"
    die "More than one matching adapter was found. Disconnect other matching adapters and rerun."
fi

DEVICE="${matches[0]%%|*}"
SERIAL="${matches[0]#*|}"
log "Found ${DEVICE}, USB serial ${SERIAL}."

if ss -ltn 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
    existing="$(systemctl is-active rigctld 2>/dev/null || true)"
    if [[ "$existing" != "active" ]]; then
        warn "TCP port ${PORT} is already in use. The service may not start; inspect it before proceeding."
    fi
fi

log "Writing stable udev rule..."
cat > "$RULE_FILE" <<EOF
SUBSYSTEM=="tty", ATTRS{idVendor}=="${USB_VENDOR}", ATTRS{idProduct}=="${USB_PRODUCT}", ATTRS{serial}=="${SERIAL}", ENV{ID_USB_INTERFACE_NUM}=="${USB_INTERFACE}", SYMLINK+="ttyFT891", GROUP="dialout", MODE="0660"
EOF
chmod 0644 "$RULE_FILE"

log "Writing rigctld systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hamlib rigctld for Yaesu FT-891
After=network.target

[Service]
Type=simple
User=pi
SupplementaryGroups=dialout
ExecStart=$(command -v rigctld) -m ${RIG_MODEL} -r ${ALIAS} -s ${BAUD} -t ${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$SERVICE_FILE"

log "Reloading udev and applying the device rule..."
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty
udevadm settle --timeout=10 || true

if [[ ! -e "$ALIAS" ]]; then
    warn "The alias has not appeared yet. Unplug/reconnect the FT-891 USB cable or reboot, then rerun the verification."
else
    log "${ALIAS} -> $(readlink -f "$ALIAS")"
fi

log "Enabling and restarting rigctld..."
systemctl daemon-reload
systemctl enable rigctld
systemctl restart rigctld
sleep 2

if systemctl is-active --quiet rigctld; then
    log "rigctld service is active."
else
    systemctl --no-pager --full status rigctld || true
    die "rigctld did not start. Review the service status above."
fi

if [[ -e "$ALIAS" ]]; then
    log "Testing CAT frequency read..."
    if frequency="$(runuser -u pi -- rigctl -m 2 -r "localhost:${PORT}" f 2>&1)"; then
        printf '\nSUCCESS: FT-891 reports %s Hz (%s MHz).\n' "$frequency" "$(awk -v f="$frequency" 'BEGIN { printf "%.6f", f/1000000 }')"
    else
        warn "The service is running, but the CAT read failed:"
        printf '%s\n' "$frequency"
        warn "Check radio power, CAT cable, menu settings, and rigctld logs with: sudo journalctl -u rigctld -n 50 --no-pager"
    fi
else
    warn "Skipping CAT test because ${ALIAS} is missing."
fi

log "Setup finished. The service uses ${ALIAS}, not a changing ttyUSB number."
if [[ "$INITIAL_ROOT_RO" -eq 1 ]]; then
    log "The root filesystem will be returned to read-only mode on exit."
fi
