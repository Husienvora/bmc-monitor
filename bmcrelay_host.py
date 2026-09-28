"""bmcrelay_host.py - runs on the Windows PC.

Watches the real LAN (mDNS/Bonjour) for Blackmagic Camera "Remote Camera"
services and pushes them to the relay inside the Android emulator
(bmcrelay-guest, reached through `adb forward tcp:5354 tcp:5354`).
The emulator app then discovers the phone and connects to its real LAN IP.

Modes (default is what works with an iPhone as the remote camera):
  default   iOS cameras (_bmd-cam-control._tcp) are re-advertised as the Android
            service type (_bmd-cam-control-android._tcp), which is the only type the
            Android app browses. Android cameras are passed through unchanged.
  --both    every camera is advertised under both service types.
  --raw     no translation at all.

Removals are debounced: a camera must stay gone for GONE_GRACE seconds before it
is withdrawn from the emulator, so mDNS TTL flaps do not drop the app's connection.
"""
import json
import socket
import sys
import time

from zeroconf import IPVersion, ServiceBrowser, ServiceListener, Zeroconf

IOS_TYPE = "_bmd-cam-control._tcp"
ANDROID_TYPE = "_bmd-cam-control-android._tcp"
SERVICE_TYPES = [IOS_TYPE + ".local.", ANDROID_TYPE + ".local."]
GUEST_ADDR = ("127.0.0.1", 5354)
GONE_GRACE = 20.0       # seconds a camera must stay gone before it is withdrawn
HEARTBEAT = 30.0        # re-send the current list this often (guest ignores no-ops)

MODE = "both" if "--both" in sys.argv else ("raw" if "--raw" in sys.argv else "translate")


def ts():
    return time.strftime("%H:%M:%S")


class Listener(ServiceListener):
    def __init__(self):
        self.services = {}      # name -> record
        self.gone_since = {}    # name -> time first seen gone
        self.dirty = True

    def _upsert(self, zc, stype, name):
        info = zc.get_service_info(stype, name, timeout=3000)
        if not info or not info.port:
            return
        ips = info.parsed_addresses(version=IPVersion.V4Only)
        if not ips:
            return
        instance = name[: -len("." + stype)] if name.endswith("." + stype) else name
        host = (info.server or "").rstrip(".")
        if host.endswith(".local"):
            host = host[: -len(".local")]
        if not host:
            host = "bmc-" + instance.lower().replace(" ", "-")
        txt = []
        for k, v in sorted((info.properties or {}).items()):
            k = k.decode() if isinstance(k, bytes) else str(k)
            if v is None:
                txt.append(k)
            else:
                v = v.decode(errors="replace") if isinstance(v, bytes) else str(v)
                txt.append(f"{k}={v}")
        rec = {"instance": instance, "service": stype[: -len(".local.")], "port": info.port,
               "host": host, "ips": sorted(ips), "txt": txt}
        self.gone_since.pop(name, None)
        if self.services.get(name) != rec:
            label = dict(kv.split("=", 1) for kv in txt if "=" in kv).get("name", instance)
            self.services[name] = rec
            self.dirty = True
            print(f"{ts()}  LAN camera: {label}  {ips[0]}:{info.port}  ({rec['service']})", flush=True)

    def add_service(self, zc, stype, name):
        self._upsert(zc, stype, name)

    def update_service(self, zc, stype, name):
        self._upsert(zc, stype, name)

    def remove_service(self, zc, stype, name):
        if name in self.services and name not in self.gone_since:
            self.gone_since[name] = time.time()

    def expire(self):
        now = time.time()
        for name, t in list(self.gone_since.items()):
            if now - t >= GONE_GRACE:
                rec = self.services.pop(name, None)
                del self.gone_since[name]
                if rec:
                    self.dirty = True
                    print(f"{ts()}  LAN camera gone: {rec['instance']}", flush=True)


def shape(records):
    out = {}
    for r in records:
        if MODE == "raw":
            types = [r["service"]]
        elif MODE == "both":
            types = [IOS_TYPE, ANDROID_TYPE]
        else:  # translate
            types = [ANDROID_TYPE]
        for t in types:
            out[(t, r["instance"])] = {**r, "service": t}
    return [out[k] for k in sorted(out)]


def push(services):
    payload = json.dumps({"services": services}).encode() + b"\n"
    with socket.create_connection(GUEST_ADDR, timeout=3) as s:
        s.sendall(payload)
        try:
            return s.recv(200).decode().strip()
        except OSError:
            return ""


def main():
    print(f"bmcrelay-host ({MODE} mode): watching the LAN for Blackmagic Camera remote cameras.")
    print("Put the iPhone in Settings > Remote Camera Control > Use This Phone as: Remote Camera.")
    print("Press Ctrl+C to stop.\n", flush=True)
    zc = Zeroconf()
    listener = Listener()
    browsers = [ServiceBrowser(zc, t, listener) for t in SERVICE_TYPES]
    last_push = 0.0
    last_err = ""
    try:
        while True:
            listener.expire()
            if listener.dirty or time.time() - last_push > HEARTBEAT:
                try:
                    reply = push(shape(listener.services.values()))
                    if listener.dirty:
                        n = len(listener.services)
                        print(f"{ts()}  emulator updated ({n} camera(s)) {reply}" if n else
                              f"{ts()}  no remote cameras on LAN (emulator list cleared)", flush=True)
                    listener.dirty = False
                    last_push = time.time()
                    last_err = ""
                except OSError as e:
                    msg = f"cannot reach relay in emulator ({e}); is the emulator running?"
                    if msg != last_err:
                        print(f"{ts()}  {msg}", flush=True)
                        last_err = msg
                    last_push = time.time() - HEARTBEAT + 5  # retry in ~5 s
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        for b in browsers:
            b.cancel()
        zc.close()


if __name__ == "__main__":
    main()
