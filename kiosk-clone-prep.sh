#!/bin/bash
# ==============================================================================
# KIOSK CLONE PREP
#
# Run ONCE on the first boot of an SD card that was cloned from the golden
# kiosk image, BEFORE it shares the network with its sibling kiosks.
#
# Gives the clone its own identity:
#   - machine-id     (otherwise DHCP can hand duplicate IPs to clones)
#   - hostname       (unique name on the network)
#   - KIOSK_ID       (how the calendar server addresses this display)
#   - SSH host keys  (clones must not share private host keys)
#
# Run:
#   sudo bash kiosk-clone-prep.sh
# ==============================================================================

set -euo pipefail

KIOSK_CONF="/etc/kiosk/kiosk.conf"

if [[ "${EUID}" -ne 0 ]]; then
    echo "[!] Run as root: sudo bash kiosk-clone-prep.sh"
    exit 1
fi

echo "Current hostname:   $(hostname)"
if [[ -f "${KIOSK_CONF}" ]] && grep -q '^KIOSK_ID=' "${KIOSK_CONF}"; then
    echo "Current KIOSK_ID:   $(grep '^KIOSK_ID=' "${KIOSK_CONF}" | cut -d= -f2-)"
fi
echo

read -rp "New hostname (e.g. kiosk-lobby): " NEW_HOST
read -rp "New KIOSK_ID (e.g. kiosk-lobby): " NEW_ID

if [[ -z "${NEW_HOST}" || -z "${NEW_ID}" ]]; then
    echo "[!] Hostname and KIOSK_ID are both required; nothing changed."
    exit 1
fi

echo
echo "Will set hostname='${NEW_HOST}', KIOSK_ID='${NEW_ID}', regenerate"
echo "machine-id and SSH host keys, then reboot."
read -rp "Continue? [y/N] " OK
[[ "${OK}" =~ ^[Yy]$ ]] || { echo "Aborted; nothing changed."; exit 1; }

echo "[+] Regenerating machine-id"
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id

echo "[+] Setting hostname"
hostnamectl set-hostname "${NEW_HOST}"
if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${NEW_HOST}/" /etc/hosts
else
    echo "127.0.1.1 ${NEW_HOST}" >> /etc/hosts
fi
# Ubuntu Pi images run cloud-init, which resets the hostname on boot unless
# told to keep it.
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-kiosk-hostname.cfg
fi

echo "[+] Setting KIOSK_ID in ${KIOSK_CONF}"
if [[ -f "${KIOSK_CONF}" ]] && grep -q '^KIOSK_ID=' "${KIOSK_CONF}"; then
    sed -i "s/^KIOSK_ID=.*/KIOSK_ID=\"${NEW_ID}\"/" "${KIOSK_CONF}"
else
    mkdir -p /etc/kiosk
    echo "KIOSK_ID=\"${NEW_ID}\"" >> "${KIOSK_CONF}"
fi

echo "[+] Regenerating SSH host keys"
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A
systemctl restart ssh || true

echo
echo "=============================================================================="
echo "CLONE PREP COMPLETE: ${NEW_HOST} / ${NEW_ID}"
echo "Rebooting in 5 seconds (Ctrl+C to cancel)..."
echo "=============================================================================="
sleep 5
systemctl reboot
