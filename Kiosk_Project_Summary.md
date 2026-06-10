# Kiosk Platform Rebuild Project

## Objective

Rebuild the Raspberry Pi facility display platform from scratch using a fully automated, reproducible deployment model.

The goal is that a freshly installed Ubuntu Server system can be converted into a complete kiosk appliance by executing a single bootstrap script.

```text
Fresh Ubuntu Server 22.04
        ↓
sudo bash kiosk-bootstrap-v3.sh
        ↓
Reboot
        ↓
Fully operational kiosk
```

---

# Design Goals

- Eliminate manual configuration
- Eliminate GNOME dependencies
- Eliminate GNOME Keyring issues
- Eliminate .desktop startup dependencies
- Use systemd for reliability
- Support remote Chromium debugging
- Support multiple kiosks
- Centralized configuration file
- OS-level emergency recovery controls
- Automatic browser recovery
- SSH management
- 4K display support

---

# Selected Platform

## Operating System

Ubuntu Server 22.04 LTS ARM64

Reasons:

- Long term support
- FIPS capability through Ubuntu Pro
- Stable ARM64 platform
- Raspberry Pi support

---

## Desktop Environment

None. No GNOME/XFCE desktop is installed.

The graphical stack is a bare X server plus Openbox (a minimal window manager)
launched directly from the kiosk user's login session.

Reasons:

- Fewest moving parts = fewest things that break on update
- No GNOME keyring, no session services, no DE update churn
- Lower memory footprint, faster boot
- Openbox keeps Chromium fullscreen and is the hook point for multi-monitor

---

## Display Manager

None. No LightDM/GDM.

Autologin is handled by `getty` on tty1, which logs the kiosk user in on the
console. The user's `.bash_profile` then runs `startx`, giving a real `logind`
session (correct `DISPLAY`, `XAUTHORITY`, `XDG_RUNTIME_DIR`, and session D-Bus).

Reasons:

- A console login session gets seat/DRM/runtime-dir correctly — the coupling
  problem that broke the old "DM + system-service-launches-browser" design
- No display manager to misconfigure XAUTHORITY
- The earlier GDM3 + GNOME build looked great but crashed on updates; this
  removes the layers that caused that

---

## Browser

Chromium

Required features:

- Kiosk mode
- Remote debugging
- JavaScript dashboard support
- Hardware acceleration support

---

# Kiosk Architecture

```text
Ubuntu Server (multi-user.target, no DM)
    ↓
getty autologin on tty1 (kiosk user)
    ↓
.bash_profile -> startx
    ↓
session.sh  (the X session)
    ├── openbox        (minimal WM)
    ├── unclutter      (hide cursor)
    └── Chromium       (kiosk, 2x scale) — relaunched in a loop if it exits

systemd Services (recovery only, run as root):
    ├── kiosk-health.service   (watch DevTools endpoint, kill+reboot escalation)
    └── reboot-hotkey.service  (A+B+C physical reboot)
```

Note: there is no longer a `kiosk-browser.service`. Chromium is launched by the
X session and kept alive by a relaunch loop in `session.sh`; the health monitor
recovers it by killing it (the loop relaunches) and reboots on repeated failure.

---

# Configuration Model

Each kiosk has a local configuration file:

```text
/etc/kiosk/kiosk.conf
```

Example:

```bash
KIOSK_URL=...
DEBUG_PORT=9223
SCALE_FACTOR=2
REBOOT_HOLD_SECONDS=15
```

Benefits:

- Same image for all kiosks
- Different URL per kiosk
- Different debugging ports per kiosk
- Easy fleet management

---

# Browser Launch

Launched by the X session script (`/opt/kiosk/scripts/session.sh`), not a
systemd unit. A `while true` loop relaunches Chromium if it exits.

Features:

- Kiosk mode
- Full screen
- Crisp 4K rendering via `--force-device-scale-factor=2`
- Automatic relaunch on crash (session loop)
- Cursor hidden (unclutter)
- Screen blanking disabled (xset)
- Remote debugging bound to 127.0.0.1 (reach via SSH tunnel)

Launch command:

```bash
chromium --kiosk --start-fullscreen \
  --force-device-scale-factor=2 --high-dpi-support=1 \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9223 \
  "$KIOSK_URL"
```

`SCALE_FACTOR` and `DEBUG_PORT` are read from `/etc/kiosk/kiosk.conf`.

---

# Health Monitoring

Service:

```text
kiosk-health.service
```

Purpose:

Detect browser failures and recover automatically.

Monitoring method:

```text
http://127.0.0.1:<DEBUG_PORT>/json/version
```

This validates:

- Chromium is running
- Chromium is responsive
- Chromium debugging endpoint is alive

Recovery flow:

```text
Failure detected
        ↓
Kill Chromium (session loop relaunches it)
        ↓
Repeated failures
        ↓
System reboot
```

Optional memory monitoring support added.

---

# Emergency Reboot System

Service:

```text
reboot-hotkey.service
```

Purpose:

Allow physical recovery without SSH access.

Hardware:

3-key USB keyboard

Mappings:

```text
A
B
C
```

Logic:

```text
Hold A+B+C
        ↓
15 seconds
        ↓
systemctl reboot
```

Advantages:

- Works even if Chromium crashes
- Works even if dashboard is frozen
- Works even if webpage JavaScript is dead
- Operates below browser layer

---

# Remote Debugging

Enabled by default.

Configurable via:

```text
DEBUG_PORT
```

Examples:

```text
Kiosk 1 = 9223
Kiosk 2 = 9224
Kiosk 3 = 9225
```

Uses Chromium DevTools protocol.

Supports:

- Performance analysis
- Memory leak analysis
- Console inspection
- Network tracing

---

# Fleet Strategy

Single golden image.

Per-device changes only:

```text
Hostname
KIOSK_URL
DEBUG_PORT
```

Everything else remains identical.

---

# Future Enhancements

## FIPS

Enable Ubuntu Pro and FIPS mode after baseline validation.

## Dedicated Keyboard Detection

Current version scans for devices exposing:

```text
KEY_A
KEY_B
KEY_C
```

Future version should lock to a specific USB device.

## Health Improvements

Potential additions:

- Dashboard endpoint monitoring
- Chromium memory thresholds
- Daily maintenance reboot window

## Configuration Management

Possible migration to:

- Ansible
- Git repository
- CI image generation

---

# Current Status

Completed:

- Architecture design
- Service model
- Config model
- Browser launch design
- Health monitor design
- Emergency reboot design
- Bootstrap v3 generation

Next Steps:

1. Build VM
2. Execute bootstrap
3. Reboot
4. Validate Chromium launch
5. Validate debugging endpoint
6. Validate hotkey reboot
7. Clone to Raspberry Pi hardware
8. Create golden image
