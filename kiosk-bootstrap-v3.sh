#!/bin/bash
# ==============================================================================
# KIOSK BOOTSTRAP V3
# Target: Ubuntu Server 24.04 LTS ARM64 / Raspberry Pi 5 (also works in a VM)
#         (22.04 works too, but 22.04 does NOT boot on a Pi 5 — use 24.04)
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
    xterm \
    unclutter \
    dbus-x11 \
    dbus-user-session \
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
# Never clobber an existing config — re-running the bootstrap must preserve
# per-device settings (URL, scale, resolution).
if [ -f "${KIOSK_CONF}" ]; then
    echo "[+] ${KIOSK_CONF} already exists; keeping it"
else
cat > "${KIOSK_CONF}" <<'EOF'
# ==============================================================================
# Kiosk configuration
# Edit this file per kiosk, then `sudo reboot` (or restart the session).
# ==============================================================================

KIOSK_URL="http://192.168.10.233:8000/calendar.html"

# Identity of this kiosk. Appended to KIOSK_URL as ?id=<KIOSK_ID> so the
# server knows which display it is talking to when sending signals.
# Give every kiosk a unique id.
KIOSK_ID="kiosk-facility"

# Remote DevTools port. Bound to 127.0.0.1 only — reach it with an SSH tunnel:
#   ssh -L 9223:127.0.0.1:9223 kiosk@<device>
# Give each kiosk a unique port if you tunnel several at once.
DEBUG_PORT="9223"

# Device scale factor. 2 = crisp rendering on a 4K display, 1 for 1080p/VMs.
SCALE_FACTOR="2"

# Display resolution: "auto" picks the output's preferred mode, or set an
# explicit mode like "1920x1080" (must be listed by `xrandr`).
RESOLUTION="auto"

# 1 = software rendering (required in VMs — Chromium crashes on virtual GPUs).
# 0 = GPU acceleration (use on real hardware like the Pi 5, smoother at 4K).
DISABLE_GPU="1"

# Hold physical A+B+C keys for this many seconds to force reboot.
REBOOT_HOLD_SECONDS="15"

# Health monitor behavior.
HEALTH_INTERVAL_SECONDS="60"
HEALTH_FAILS_BEFORE_BROWSER_RESTART="5"
HEALTH_BROWSER_RESTARTS_BEFORE_REBOOT="3"

# Browser memory ceiling in MB. Set to 0 to disable memory-based restart.
CHROMIUM_MAX_MEMORY_MB="0"
EOF
fi

chmod 644 "${KIOSK_CONF}"

echo "[+] Writing Xorg config for Raspberry Pi KMS"
# Bind the Pi's vc4 display driver to Xorg's modesetting driver. Without
# this, X autoconfig on the Pi can fall back to legacy fbdev and die with
# "Cannot run in framebuffer mode. Please specify busIDs for all
# framebuffer devices". No effect on machines without vc4 (VMs etc).
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/99-vc4-kms.conf <<'EOF'
Section "OutputClass"
    Identifier "vc4"
    MatchDriver "vc4"
    Driver "modesetting"
    Option "PrimaryGPU" "true"
EndSection
EOF

echo "[+] Configuring silent boot with splash cover"
apt-get install -y plymouth plymouth-themes

# Custom Plymouth theme: shows splash.png centered on black if one was
# shipped next to this script, plain black otherwise.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p /usr/share/plymouth/themes/kiosk
if [ -f "${SCRIPT_DIR}/splash.png" ]; then
    cp "${SCRIPT_DIR}/splash.png" /usr/share/plymouth/themes/kiosk/splash.png
fi

cat > /usr/share/plymouth/themes/kiosk/kiosk.plymouth <<'EOF'
[Plymouth Theme]
Name=Kiosk
Description=Black screen with optional cover image
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/kiosk
ScriptFile=/usr/share/plymouth/themes/kiosk/kiosk.script
EOF

cat > /usr/share/plymouth/themes/kiosk/kiosk.script <<'EOF'
Window.SetBackgroundTopColor(0, 0, 0);
Window.SetBackgroundBottomColor(0, 0, 0);

image = Image("splash.png");
if (image) {
    screen_w = Window.GetWidth();
    screen_h = Window.GetHeight();
    ratio_w = screen_w / image.GetWidth();
    ratio_h = screen_h / image.GetHeight();
    ratio = ratio_w;
    if (ratio_h < ratio_w)
        ratio = ratio_h;
    scaled = image.Scale(image.GetWidth() * ratio, image.GetHeight() * ratio);
    sprite = Sprite(scaled);
    sprite.SetPosition((screen_w - scaled.GetWidth()) / 2,
                       (screen_h - scaled.GetHeight()) / 2, 0);
}
EOF

plymouth-set-default-theme kiosk
update-initramfs -u

# Silence kernel/systemd text on the console.
QUIET_PARAMS="quiet splash loglevel=3 logo.nologo vt.global_cursor_off=1 systemd.show_status=false plymouth.ignore-serial-consoles"
if [ -f /boot/firmware/cmdline.txt ]; then
    # Raspberry Pi: single-line kernel cmdline.
    for p in ${QUIET_PARAMS}; do
        grep -qw "${p}" /boot/firmware/cmdline.txt || sed -i "s/\$/ ${p}/" /boot/firmware/cmdline.txt
    done
    # Also silence the firmware's rainbow splash before the kernel loads.
    grep -q '^disable_splash=' /boot/firmware/config.txt 2>/dev/null || \
        echo 'disable_splash=1' >> /boot/firmware/config.txt
elif [ -f /etc/default/grub ]; then
    # VM / generic install.
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"${QUIET_PARAMS}\"/" /etc/default/grub
    update-grub
fi

# No "Last login" / motd noise on the autologin console.
touch "${KIOSK_HOME}/.hushlogin"
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.hushlogin"

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
#
# Failsafe: if X dies 3 times within 2 minutes, stop relaunching and leave a
# usable shell on tty1 instead of a flicker loop. /tmp is cleared at boot, so
# every boot gets fresh attempts; a reboot also retries.
if [ -z "${DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = "1" ]; then
    GUARD="/tmp/kiosk-x-failures"
    NOW="$(date +%s)"
    RECENT=0
    if [ -f "$GUARD" ]; then
        RECENT="$(awk -v now="$NOW" '$1 > now-120' "$GUARD" | wc -l)"
    fi
    if [ "$RECENT" -ge 3 ]; then
        echo "kiosk: X failed $RECENT times in 2 minutes — staying in this shell."
        echo "kiosk: check /opt/kiosk/logs/chromium.log and Xorg logs."
        echo "kiosk: 'rm $GUARD' then log out, or reboot, to retry the kiosk."
    else
        echo "$NOW" >> "$GUARD"
        exec startx /opt/kiosk/scripts/session.sh -- :0 vt1 -nolisten tcp
    fi
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
: "${KIOSK_ID:=}"
: "${SCALE_FACTOR:=2}"
: "${DEBUG_PORT:=9223}"
: "${RESOLUTION:=auto}"
# Default to software rendering when unset — safe everywhere, required in VMs.
: "${DISABLE_GPU:=1}"

GPU_FLAGS=""
[ "$DISABLE_GPU" = "1" ] && GPU_FLAGS="--disable-gpu"

# Append the kiosk identity to the URL (handles URLs with or without an
# existing query string).
if [ -n "$KIOSK_ID" ]; then
    case "$KIOSK_URL" in
        *\?*) KIOSK_URL="${KIOSK_URL}&id=${KIOSK_ID}" ;;
        *)    KIOSK_URL="${KIOSK_URL}?id=${KIOSK_ID}" ;;
    esac
fi

log() { logger -t kiosk-session "$*"; echo "kiosk-session: $*"; }

# Persistent browser log (survives reboots, unlike /tmp). Truncated each
# session start so a crash loop can't slowly fill the disk.
CHROMIUM_LOG="/opt/kiosk/logs/chromium.log"
: > "$CHROMIUM_LOG" 2>/dev/null || CHROMIUM_LOG="/tmp/kiosk-chromium.log"

# Resolve Chromium at runtime (snap path or deb), independent of install method.
CHROMIUM_BIN="$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || true)"
[ -z "$CHROMIUM_BIN" ] && [ -x /snap/bin/chromium ] && CHROMIUM_BIN="/snap/bin/chromium"
if [ -z "$CHROMIUM_BIN" ]; then
    log "FATAL: chromium not found; holding session"
    sleep 30
    exit 1
fi
log "Using chromium at $CHROMIUM_BIN"

# Snap apps must reach the systemd *user* instance over the user D-Bus to
# create their tracking cgroup ("session-N.scope is not a snap cgroup"
# otherwise). dbus-launch creates a detached bus with no systemd on it, so
# prefer the real user bus and only fall back to dbus-launch if it's missing.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
    log "Using systemd user bus at ${XDG_RUNTIME_DIR}/bus"
elif [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    log "WARNING: no user bus socket; falling back to dbus-launch (snaps may fail)"
    eval "$(dbus-launch --sh-syntax)"
fi

# Disable screen blanking and power management (best-effort).
xset s off || true
xset -dpms || true
xset s noblank || true

# Black root window so the moment before Chromium paints isn't gray.
xsetroot -solid black || true

# Apply the configured resolution to the first connected output. Without this,
# a VM's virtual display often comes up at a tiny default mode.
XOUTPUT="$(xrandr --query 2>/dev/null | awk '/ connected/{print $1; exit}')"
if [ -n "$XOUTPUT" ]; then
    if [ "$RESOLUTION" = "auto" ]; then
        xrandr --output "$XOUTPUT" --auto || true
    elif ! xrandr --output "$XOUTPUT" --mode "$RESOLUTION"; then
        log "Mode $RESOLUTION not available on $XOUTPUT; falling back to auto"
        xrandr --output "$XOUTPUT" --auto || true
    fi
    log "Display: $(xrandr --query | awk '/\*/{print $1; exit}') on $XOUTPUT"
fi

# Hide the mouse pointer almost immediately.
pkill -x unclutter || true
unclutter -idle 0.1 -root >/tmp/kiosk-unclutter.log 2>&1 &

# Minimal window manager: keeps Chromium fullscreen and is the hook point for
# future multi-monitor layouts (xrandr + per-output windows).
openbox &
sleep 1

# Launch Chromium and relaunch it if it ever exits. While the pause flag
# exists (Ctrl+Alt+Q), stay closed so a maintainer can work undisturbed;
# Ctrl+Alt+R removes the flag and brings the browser back.
PAUSE_FLAG="/tmp/kiosk-pause"
while true; do
    if [ -f "$PAUSE_FLAG" ]; then
        sleep 2
        continue
    fi
    log "Launching Chromium -> $KIOSK_URL"
    "$CHROMIUM_BIN" \
        --kiosk \
        $GPU_FLAGS \
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
        >>"$CHROMIUM_LOG" 2>&1 || true
    log "Chromium exited; relaunching in 3s"
    sleep 3
done
EOF

chmod +x "${KIOSK_DIR}/scripts/session.sh"
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.bash_profile"
# The session (running as kiosk) writes the browser log here.
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_DIR}/logs"

echo "[+] Writing openbox config (terminal escape hatch)"
# Ctrl+Alt+T opens a terminal and Ctrl+Alt+R restarts the browser — these are
# openbox global grabs, so they work even with Chromium fullscreen on top.
# The right-click root menu carries the same actions for when the browser is
# down. `systemctl reboot` works unprivileged because the kiosk user holds an
# active local logind session (polkit allow_active).
mkdir -p "${KIOSK_HOME}/.config/openbox"

cp /etc/xdg/openbox/rc.xml "${KIOSK_HOME}/.config/openbox/rc.xml"
# Each action is bound to Ctrl+Alt and Ctrl+Super: keyboards with a
# Mac/Windows switch swap Alt and Super at the key next to the spacebar,
# so binding both means the same physical chord works in either mode.
sed -i 's|</keyboard>|  <keybind key="C-A-t"><action name="Execute"><command>xterm -fa Monospace -fs 14</command></action></keybind>\n  <keybind key="C-W-t"><action name="Execute"><command>xterm -fa Monospace -fs 14</command></action></keybind>\n  <keybind key="C-A-r"><action name="Execute"><command>sh -c "rm -f /tmp/kiosk-pause; pkill -f chromium"</command></action></keybind>\n  <keybind key="C-W-r"><action name="Execute"><command>sh -c "rm -f /tmp/kiosk-pause; pkill -f chromium"</command></action></keybind>\n  <keybind key="C-A-q"><action name="Execute"><command>sh -c "touch /tmp/kiosk-pause; pkill -f chromium"</command></action></keybind>\n  <keybind key="C-W-q"><action name="Execute"><command>sh -c "touch /tmp/kiosk-pause; pkill -f chromium"</command></action></keybind>\n</keyboard>|' \
    "${KIOSK_HOME}/.config/openbox/rc.xml"

cat > "${KIOSK_HOME}/.config/openbox/menu.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Kiosk">
    <item label="Terminal (xterm)">
      <action name="Execute"><command>xterm -fa Monospace -fs 14</command></action>
    </item>
    <item label="Restart Browser">
      <action name="Execute"><command>sh -c "rm -f /tmp/kiosk-pause; pkill -f chromium"</command></action>
    </item>
    <item label="Close Browser (stay closed)">
      <action name="Execute"><command>sh -c "touch /tmp/kiosk-pause; pkill -f chromium"</command></action>
    </item>
    <separator/>
    <item label="Reboot">
      <action name="Execute"><command>systemctl reboot</command></action>
    </item>
  </menu>
</openbox_menu>
EOF

chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config"

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
                        # keystate 1 = down, 2 = autorepeat while held.
                        # Counting only 1 made every hold self-reset as soon
                        # as the keyboard started repeating.
                        pressed[c] = key.keystate in (1, 2)

        except BlockingIOError:
            pass
        except OSError:
            try:
                devices.remove(dev)
            except ValueError:
                pass
        except Exception:
            pass

    # Check the hold timer on every poll tick, NOT inside the event handler:
    # while keys are held no new events may arrive (not all keyboards emit
    # autorepeat at the evdev level), so an event-driven check never fires.
    if all(pressed.values()):
        if start is None:
            start = time.time()
            log("A+B+C reboot hold started")
        elif time.time() - start >= read_hold_seconds():
            log("Emergency reboot hotkey triggered")
            os.system("sync")
            os.system("systemctl reboot")
            start = None
    else:
        start = None

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
echo "  - Ctrl+Alt+T opens a terminal over the kiosk (escape hatch)"
echo "  - Ctrl+Alt+Q closes Chromium and keeps it closed (maintenance)"
echo "  - Ctrl+Alt+R restarts Chromium / resumes after Ctrl+Alt+Q"
echo "  - Browser log: /opt/kiosk/logs/chromium.log (persistent)"
echo
