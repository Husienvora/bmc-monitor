# bmc-monitor

Use a Windows PC as a **Blackmagic Camera controller / monitor** for a phone running the
Blackmagic Camera app (tested target: iPhone 17 Pro). Live video feed, focus, exposure,
record start/stop, from the PC, via the official Blackmagic Camera Android app running in
the Android emulator.

## Install (any Windows 10/11 PC, no admin needed)

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/Husienvora/bmc-monitor/main/install.ps1 | iex
```

Or clone the repo and run `powershell -ExecutionPolicy Bypass -File install.ps1`.

It installs, per user: JDK 17, Python 3, Android command-line tools, the emulator and an
Android 16 x86_64 image (about 1.5 GB), creates the `BMC_Monitor` virtual device, downloads
the Blackmagic Camera APK, and puts a **Blackmagic Monitor** shortcut on the Desktop.
Takes 5 to 15 minutes depending on the connection. Needs hardware virtualization (VT-x / AMD-V).

## Use

1. Double-click **Blackmagic Monitor** on the Desktop. Two windows open: the emulator
   (with the Blackmagic Camera app) and a relay console. Leave the console open.
2. First time only, in the emulator app: Settings > Remote Camera Control > **On**,
   Use This Phone as: **Controller**.
3. On the iPhone: Settings > Remote Camera Control > **On**, Use This iPhone as:
   **Remote Camera**. Same Wi-Fi / LAN as the PC.
4. The relay console prints `LAN camera found: ...` when it sees the iPhone.
5. In the emulator, Camera tab > left `⋮` > remote cameras icon > pick the iPhone.

If the console shows the iPhone but the emulator list stays empty, start the relay with
both service types mirrored:

```
powershell -ExecutionPolicy Bypass -File start-bmc-monitor.ps1 --both
```

## How it works

The Blackmagic Camera app discovers remote cameras only through mDNS (Bonjour) and has no
manual IP entry on Android. The emulator sits behind NAT, so LAN multicast never reaches it.

- `bmcrelay_host.py` (PC side, Python + `zeroconf`) browses the LAN for
  `_bmd-cam-control._tcp` / `_bmd-cam-control-android._tcp` and pushes what it finds over
  `adb forward tcp:5354` into the emulator.
- `bmcrelay-guest` (emulator side, static Go binary, source in `guest/`) re-advertises those
  records inside the emulator. The app then connects straight to the phone's LAN IP.

## Files

| File | Purpose |
|------|---------|
| `install.ps1` | one-shot setup |
| `Blackmagic Monitor.cmd` / `start-bmc-monitor.ps1` | launcher: boots emulator, installs app if missing, starts both relays |
| `bmcrelay_host.py` | LAN side relay |
| `bmcrelay-guest`, `guest/main.go` | emulator side relay (rebuild: `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w" -o bmcrelay-guest ./guest`) |
| `apk/` | Blackmagic Camera splits, filled by `install.ps1` (not in git) |

## Known limits

- Discovery inside the emulator was verified with a synthetic record; end-to-end with a real
  phone depends on the app's own protocol working through NAT (TCP works; inbound UDP would not).
  Fallback if the feed does not appear: bridged networking with a TAP adapter (`emulator -net-tap`),
  which needs admin rights.
- The Blackmagic Camera app is Blackmagic Design's software and is downloaded at install time
  from a public mirror. Nothing of it is redistributed in this repo.
