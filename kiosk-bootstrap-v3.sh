#!/bin/bash
# ==============================================================================
# KIOSK BOOTSTRAP V3
# Target: Ubuntu Server 22.04 ARM64 / Raspberry Pi (also works in a VM)
#
# Goal:
#   Fresh minimal Ubuntu Server -> run this once -> reboot -> kiosk comes up.
#
# Architecture (no display manager, no desktop environment):
#   getty autologin on tty1 (kiosk user)
#        -> .bash_profile execs startx
#             -> /opt/kiosk/scripts/session.sh  (the X session)
#                  -> openbox + unclutter + Chromium (kiosk, 2x scale)
#
#   systemd owns nothing graphical except recovery:
#     - kiosk-health.service   : watches Chromium debug endpoint, recovers
#     - reboot-hotkey.service  : A+B+C physical reboot, independent of browser
#
#   Why this shape:
#     - The graphical session is a real logind session on tty1, so DISPLAY,
#       XAUTHORITY, XDG_RUNTIME_DIR and the session D-Bus are all correct.
#       (This was the failure mode of the old DM + system-service design.)
#     - No GNOME / GDM / keyring. Snap-Chromium auto-refresh is held so an
#       update can't restart the browser mid-display.
#
# Run:
#   sudo bash kiosk-bootstrap-v3.sh
# ==============================================================================

set -euo pipefail

KIOSK_USER="kiosk"
KIOSK_HOME="/home/${KIOSK_USER}"
KIOSK_DIR="/opt/kiosk"
KIOSK_CONF="/etc/kiosk/kiosk.conf"

echo "[+] Starting kiosk bootstrap v3"

if [[ "${EUID}" -ne 0 ]]; then
    echo "[!] Run as root: sudo bash kiosk-bootstrap-v3.sh"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[+] Updating package lists"
apt-get update

echo "[+] Upgrading existing packages"
apt-get upgrade -y

echo "[+] Installing X, window manager and kiosk tooling (no desktop environment)"
apt-get install -y \
    xserver-xorg \
    xinit \
    xauth \
    x11-xserver-utils \
    openbox \
    unclutter \
    dbus-x11 \
    fonts-liberation \
    fonts-noto-core \
    fonts-noto-color-emoji \
    python3 \
    python3-evdev \
    snapd \
    curl \
    wget \
    openssh-server \
    procps \
    psmisc \
    ca-certificates

echo "[+] Installing Chromium (snap is the only maintained Chromium on 22.04 ARM64)"
systemctl enable --now snapd
# snap can take a moment to be ready right after enable.
snap wait system seed.loaded || true
snap install chromium

echo "[+] Holding Chromium snap auto-refresh (prevents surprise restarts on a kiosk)"
snap refresh --hold chromium || echo "[!] Could not hold chromium snap refresh (non-fatal)"

echo "[+] Verifying Chromium executable"
CHROMIUM_BIN="$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || true)"
if [[ -z "${CHROMIUM_BIN}" && -x /snap/bin/chromium ]]; then
    CHROMIUM_BIN="/snap/bin/chromium"
fi
if [[ -z "${CHROMIUM_BIN}" ]]; then
    echo "[!] Chromium was not found after installation"
    exit 1
fi
echo "[+] Chromium command: ${CHROMIUM_BIN}"

echo "[+] Creating kiosk user"
if ! id "${KIOSK_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${KIOSK_USER}"
fi

# Passwordless local account so getty can autologin without a prompt.
# SSH password auth is governed separately by sshd (empty passwords are
# refused by default), so this does not open passwordless SSH.
passwd -d "${KIOSK_USER}" || true

echo "[+] Adding kiosk user to graphics/input groups (needed to drive X without a DM)"
for g in video input render tty audio; do
    getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "${KIOSK_USER}"
done

echo "[+] Creating kiosk directories"
mkdir -p /etc/kiosk
mkdir -p "${KIOSK_DIR}/scripts"
mkdir -p "${KIOSK_DIR}/logs"

echo "[+] Writing kiosk config"
cat > "${KIOSK_CONF}" <<'EOF'
# ==============================================================================
# Kiosk configuration
# Edit this file per kiosk, then `sudo reboot` (or restart the session).
# ==============================================================================

KIOSK_URL="http://192.168.10.233:8000/calendar.html?id=kiosk-facility"

# Remote DevTools port. Bound to 127.0.0.1 only — reach it with an SSH tunnel:
#   ssh -L 9223:127.0.0.1:9223 kiosk@<device>
# Give each kiosk a unique port if you tunnel several at once.
DEBUG_PORT="9223"

# Device scale factor. 2 = crisp rendering on a 4K display.
SCALE_FACTOR="2"

# Hold physical A+B+C keys for this many seconds to force reboot.
REBOOT_HOLD_SECONDS="15"

# Health monitor behavior.
HEALTH_INTERVAL_SECONDS="60"
HEALTH_FAILS_BEFORE_BROWSER_RESTART="5"
HEALTH_BROWSER_RESTARTS_BEFORE_REBOOT="3"

# Browser memory ceiling in MB. Set to 0 to disable memory-based restart.
CHROMIUM_MAX_MEMORY_MB="0"
EOF

chmod 644 "${KIOSK_CONF}"

echo "[+] Setting default target to multi-user (no graphical.target / DM)"
systemctl set-default multi-user.target

echo "[+] Configuring getty autologin on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF

echo "[+] Writing kiosk login hook (.bash_profile -> startx)"
cat > "${KIOSK_HOME}/.bash_profile" <<'EOF'
# Start the kiosk X session automatically on the first virtual terminal.
# startx replaces this shell; when X exits, getty respawns and we come back.
if [ -z "${DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = "1" ]; then
    exec startx /opt/kiosk/scripts/session.sh -- :0 vt1 -nolisten tcp
fi
EOF

echo "[+] Writing X session script"
cat > "${KIOSK_DIR}/scripts/session.sh" <<'EOF'
#!/bin/bash
# Kiosk X session. Launched by startx as the kiosk user, so it inherits a real
# logind session: DISPLAY, XAUTHORITY, XDG_RUNTIME_DIR and the user D-Bus.
set -uo pipefail

CONF="/etc/kiosk/kiosk.conf"
# shellcheck source=/dev/null
[ -r "$CONF" ] && source "$CONF"

: "${KIOSK_URL:=about:blank}"
: "${SCALE_FACTOR:=2}"
: "${DEBUG_PORT:=9223}"

log() { logger -t kiosk-session "$*"; echo "kiosk-session: $*"; }

# Resolve Chromium at runtime (snap path or deb), independent of install method.
CHROMIUM_BIN="$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || true)"
[ -z "$CHROMIUM_BIN" ] && [ -x /snap/bin/chromium ] && CHROMIUM_BIN="/snap/bin/chromium"
if [ -z "$CHROMIUM_BIN" ]; then
    log "FATAL: chromium not found; holding session"
    sleep 30
    exit 1
fi
log "Using chromium at $CHROMIUM_BIN"

# Ensure a session bus exists for Chromium / unclutter.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    eval "$(dbus-launch --sh-syntax)"
fi

# Disable screen blanking and power management (best-effort).
xset s off || true
xset -dpms || true
xset s noblank || true

# Hide the mouse pointer almost immediately.
pkill -x unclutter || true
unclutter -idle 0.1 -root >/tmp/kiosk-unclutter.log 2>&1 &

# Minimal window manager: keeps Chromium fullscreen and is the hook point for
# future multi-monitor layouts (xrandr + per-output windows).
openbox &
sleep 1

# Launch Chromium and relaunch it if it ever exits.
while true; do
    log "Launching Chromium -> $KIOSK_URL"
    "$CHROMIUM_BIN" \
        --kiosk \
        --start-fullscreen \
        --force-device-scale-factor="$SCALE_FACTOR" \
        --high-dpi-support=1 \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-translate \
        --disable-features=Translate,MediaRouter \
        --disable-notifications \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --autoplay-policy=no-user-gesture-required \
        --password-store=basic \
        --remote-debugging-address=127.0.0.1 \
        --remote-debugging-port="$DEBUG_PORT" \
        "$KIOSK_URL" \
        >/tmp/kiosk-chromium.log 2>&1 || true
    log "Chromium exited; relaunching in 3s"
    sleep 3
done
EOF

chmod +x "${KIOSK_DIR}/scripts/session.sh"
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.bash_profile"

echo "[+] Writing health monitor"
cat > "${KIOSK_DIR}/scripts/health-monitor.py" <<'EOF'
#!/usr/bin/env python3
import time
import subprocess
import urllib.request

CONF = "/etc/kiosk/kiosk.conf"

def read_conf():
    cfg = {
        "DEBUG_PORT": "9223",
        "HEALTH_INTERVAL_SECONDS": "60",
        "HEALTH_FAILS_BEFORE_BROWSER_RESTART": "5",
        "HEALTH_BROWSER_RESTARTS_BEFORE_REBOOT": "3",
        "CHROMIUM_MAX_MEMORY_MB": "0",
    }
    try:
        with open(CONF, "r") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except Exception:
        pass
    return cfg

def log(msg):
    subprocess.run(["logger", "-t", "kiosk-health", msg])

def kill_browser():
    # The session.sh loop relaunches Chromium as soon as it dies.
    log("Killing Chromium; session loop will relaunch it")
    subprocess.run(["pkill", "-f", "chromium"])

def reboot_system():
    log("Rebooting system due to repeated kiosk health failures")
    subprocess.run(["systemctl", "reboot"])

def debug_endpoint_ok(port):
    url = f"http://127.0.0.1:{port}/json/version"
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.status == 200
    except Exception:
        return False

def chromium_memory_mb():
    try:
        out = subprocess.check_output(
            "ps -C chromium-browser -C chromium -o rss= 2>/dev/null || true",
            shell=True, text=True,
        )
        total_kb = 0
        for line in out.splitlines():
            try:
                total_kb += int(line.strip())
            except Exception:
                pass
        return int(total_kb / 1024)
    except Exception:
        return 0

fails = 0
browser_restarts = 0

log("Kiosk health monitor started")

while True:
    cfg = read_conf()
    port = cfg["DEBUG_PORT"]
    interval = int(cfg["HEALTH_INTERVAL_SECONDS"])
    fail_limit = int(cfg["HEALTH_FAILS_BEFORE_BROWSER_RESTART"])
    reboot_limit = int(cfg["HEALTH_BROWSER_RESTARTS_BEFORE_REBOOT"])
    max_mem = int(cfg["CHROMIUM_MAX_MEMORY_MB"])

    if debug_endpoint_ok(port):
        fails = 0
        browser_restarts = 0
    else:
        fails += 1
        log(f"Chromium debug endpoint failed {fails}/{fail_limit} on port {port}")

    if max_mem > 0:
        mem = chromium_memory_mb()
        if mem > max_mem:
            log(f"Chromium memory {mem}MB exceeded limit {max_mem}MB")
            kill_browser()
            fails = 0
            browser_restarts += 1

    if fails >= fail_limit:
        kill_browser()
        fails = 0
        browser_restarts += 1

    if browser_restarts >= reboot_limit:
        reboot_system()

    time.sleep(interval)
EOF

chmod +x "${KIOSK_DIR}/scripts/health-monitor.py"

cat > /etc/systemd/system/kiosk-health.service <<EOF
[Unit]
Description=Kiosk Health Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${KIOSK_DIR}/scripts/health-monitor.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Writing reboot hotkey service"
cat > "${KIOSK_DIR}/scripts/reboot-hotkey.py" <<'EOF'
#!/usr/bin/env python3
import os
import time
import subprocess
from evdev import InputDevice, list_devices, categorize, ecodes

CONF = "/etc/kiosk/kiosk.conf"

def read_hold_seconds():
    hold = 15
    try:
        with open(CONF, "r") as f:
            for raw in f:
                line = raw.strip()
                if line.startswith("REBOOT_HOLD_SECONDS="):
                    hold = int(line.split("=", 1)[1].strip().strip('"').strip("'"))
    except Exception:
        pass
    return hold

def log(msg):
    subprocess.run(["logger", "-t", "reboot-hotkey", msg])

def open_devices():
    devices = []
    for path in list_devices():
        try:
            dev = InputDevice(path)
            caps = dev.capabilities().get(ecodes.EV_KEY, [])
            if ecodes.KEY_A in caps and ecodes.KEY_B in caps and ecodes.KEY_C in caps:
                devices.append(dev)
                log(f"Watching input device {path}: {dev.name}")
        except Exception:
            pass
    return devices

pressed = {"KEY_A": False, "KEY_B": False, "KEY_C": False}
start = None

devices = open_devices()
log("Reboot hotkey service started")

while True:
    if not devices:
        time.sleep(5)
        devices = open_devices()
        continue

    for dev in list(devices):
        try:
            for event in dev.read():
                if event.type != ecodes.EV_KEY:
                    continue

                key = categorize(event)
                code = key.keycode
                # keycode can be a list when a scancode maps to several names.
                codes = code if isinstance(code, list) else [code]

                for c in codes:
                    if c in pressed:
                        pressed[c] = key.keystate == 1

                if all(pressed.values()):
                    if start is None:
                        start = time.time()
                        log("A+B+C reboot hold started")

                    hold = read_hold_seconds()
                    if time.time() - start >= hold:
                        log("Emergency reboot hotkey triggered")
                        os.system("sync")
                        os.system("systemctl reboot")
                else:
                    start = None

        except BlockingIOError:
            pass
        except OSError:
            try:
                devices.remove(dev)
            except ValueError:
                pass
        except Exception:
            pass

    time.sleep(0.05)
EOF

chmod +x "${KIOSK_DIR}/scripts/reboot-hotkey.py"

cat > /etc/systemd/system/reboot-hotkey.service <<EOF
[Unit]
Description=Kiosk Emergency Reboot Hotkey
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${KIOSK_DIR}/scripts/reboot-hotkey.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "[+] Enabling SSH"
systemctl enable ssh
systemctl restart ssh || true

echo "[+] Enabling kiosk services"
systemctl daemon-reload
systemctl enable kiosk-health.service
systemctl enable reboot-hotkey.service

echo "[+] Final validation"
echo "Chromium path: ${CHROMIUM_BIN}"
echo "Default target: $(systemctl get-default)"
echo "Kiosk config:"
cat "${KIOSK_CONF}"

echo
echo "=============================================================================="
echo "KIOSK BOOTSTRAP V3 COMPLETE"
echo "=============================================================================="
echo
echo "Reboot now with:  sudo reboot"
echo
echo "After reboot, expected state:"
echo "  - tty1 autologins as ${KIOSK_USER}"
echo "  - startx launches the X session (openbox + Chromium)"
echo "  - Chromium opens KIOSK_URL fullscreen at ${SCALE_FACTOR:-2}x scale"
echo "  - DevTools listens on 127.0.0.1:DEBUG_PORT (tunnel via SSH)"
echo "  - A+B+C held for REBOOT_HOLD_SECONDS triggers an OS-level reboot"
echo
