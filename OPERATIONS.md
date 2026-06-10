# Kiosk Operations Reference

Readable on the device with:  cat ~/mac-monitor/OPERATIONS.md

## Keyboard Shortcuts

| Keys (Win mode)   | Keys (Mac mode)   | Action                                      |
|-------------------|-------------------|---------------------------------------------|
| Ctrl+Alt+T        | Ctrl+Cmd+T        | Open terminal (xterm) over the kiosk        |
| Ctrl+Alt+Q        | Ctrl+Cmd+Q        | Close browser and KEEP it closed            |
| Ctrl+Alt+R        | Ctrl+Cmd+R        | Restart browser / resume after Q            |
| A+B+C (hold)      | A+B+C (hold)      | Force OS reboot (REBOOT_HOLD_SECONDS)       |
| Ctrl+Alt+F2       | Ctrl+Alt+F2       | Console login (kiosk keeps running on tty1) |
| Ctrl+Alt+F1       | Ctrl+Alt+F1       | Back to the kiosk display                   |

Right-click the desktop (browser closed) for the same actions as a menu.
Both modifier chords are bound, so either side of a Mac/Windows-switch
keyboard works. A+B+C reads raw input -- works even if X/browser are dead.

## Common Commands

| Task                        | Command                                          |
|-----------------------------|--------------------------------------------------|
| Edit kiosk settings         | sudo nano /etc/kiosk/kiosk.conf                  |
| Apply URL/scale/GPU change  | Ctrl+Alt+R (or: pkill -f chromium)               |
| Browser log (persistent)    | cat /opt/kiosk/logs/chromium.log                 |
| Session log (this boot)     | journalctl -t kiosk-session -b                   |
| Health monitor log          | journalctl -t kiosk-health -b                    |
| Reboot hotkey log (live)    | journalctl -t reboot-hotkey -f                   |
| X server errors             | grep EE /home/kiosk/.local/share/xorg/Xorg.0.log |
| Service status              | systemctl status kiosk-health reboot-hotkey      |
| Update kiosk software       | cd ~/mac-monitor && git pull && sudo bash kiosk-bootstrap-v3.sh |
| Share a log over the net    | cat <file> \| nc termbin.com 9999                |

## Config Quick Reference (/etc/kiosk/kiosk.conf)

| Setting             | Pi 5 production | Parallels VM | Notes                        |
|---------------------|-----------------|--------------|------------------------------|
| KIOSK_ID            | unique per pi   | test value   | Appended to URL as ?id=...   |
| DISABLE_GPU         | 0               | 1            | 1 = software rendering       |
| SCALE_FACTOR        | 2 (4K panel)    | 1            |                              |
| RESOLUTION          | auto            | 1920x1080    | Must be a mode xrandr lists  |
| REBOOT_HOLD_SECONDS | 15              | 3 (testing)  | Re-read live, no restart     |

Conf changes need only Ctrl+Alt+R (browser settings) -- except RESOLUTION,
which is applied at session start: reboot for that one.

## Recovery Ladder

| Situation               | Do this                                          |
|-------------------------|--------------------------------------------------|
| Need a shell, kiosk up  | Ctrl+Alt+T, or SSH in                            |
| Browser wedged          | Ctrl+Alt+R, then check chromium.log              |
| X crash-looping         | Waits out after 3 tries -> shell on tty1; or F2  |
| Whole device wedged     | Hold A+B+C for REBOOT_HOLD_SECONDS               |
| Won't boot              | SD card in Mac, add systemd.unit=rescue.target to cmdline.txt |
