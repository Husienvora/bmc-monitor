"""bmcrelay_host.py - runs on the Windows PC.

Watches the real LAN (mDNS/Bonjour) for Blackmagic Camera "Remote Camera"
services and pushes them to the relay inside the Android emulator
(bmcrelay-guest, reached through `adb forward tcp:5354 tcp:5354`).
The emulator app then discovers the iPhone and connects to its real LAN IP.
"""
import json
import socket
import sys
import time

from zeroconf import ServiceBrowser, ServiceListener, Zeroconf

SERVICE_TYPES = ["_bmd-cam-control._tcp.local.", "_bmd-cam-control-android._tcp.local."]
GUEST_ADDR = ("127.0.0.1", 5354)
# --both: re-advertise every camera under BOTH service types inside the emulator.
# Use it if the iPhone shows up in this window but not in the emulator's camera list.
MIRROR_BOTH = "--both" in sys.argv


def ts():
    return time.strftime("%H:%M:%S")


class Listener(ServiceListener):
    def __init__(self):
        self.services = {}
        self.dirty = True

    def _upsert(self, zc, stype, name):
        info = zc.get_service_info(stype, name, timeout=3000)
        if not info or not info.port:
            return
        ips = info.parsed_addresses(version=__import__("zeroconf").IPVersion.V4Only)
        if not ips:
            return
        instance = name[: -len("." + stype)] if name.endswith("." + stype) else name
        host = (info.server or "").rstrip(".")
        if host.endswith(".local"):
            host = host[: -len(".local")]
        if not host:
            host = "bmc-" + instance.lower().replace(" ", "-")
        txt = []
        for k, v in (info.properties or {}).items():
            k = k.decode() if isinstance(k, bytes) else str(k)
            if v is None:
                txt.append(k)
            else:
                v = v.decode(errors="replace") if isinstance(v, bytes) else str(v)
                txt.append(f"{k}={v}")
        rec = {"instance": instance, "service": stype[: -len(".local.")], "port": info.port,
               "host": host, "ips": ips, "txt": txt}
        if self.services.get(name) != rec:
            self.services[name] = rec
            self.dirty = True
            print(f"{ts()}  LAN camera found: {instance}  {ips[0]}:{info.port}", flush=True)

    def add_service(self, zc, stype, name):
        self._upsert(zc, stype, name)

    def update_service(self, zc, stype, name):
        self._upsert(zc, stype, name)

    def remove_service(self, zc, stype, name):
        if name in self.services:
            print(f"{ts()}  LAN camera gone: {self.services[name]['instance']}", flush=True)
            del self.services[name]
            self.dirty = True


def push(services):
    if MIRROR_BOTH:
        mirrored = []
        for s in services:
            for t in ("_bmd-cam-control._tcp", "_bmd-cam-control-android._tcp"):
                mirrored.append({**s, "service": t})
        services = mirrored
    payload = json.dumps({"services": services}).encode() + b"\n"
    with socket.create_connection(GUEST_ADDR, timeout=3) as s:
        s.sendall(payload)


def main():
    print("bmcrelay-host: watching the LAN for Blackmagic Camera remote cameras.")
    print("Put the iPhone in Settings > Remote Camera Control > Use This Phone as: Remote Camera.")
    print("Press Ctrl+C to stop.\n", flush=True)
    zc = Zeroconf()
    listener = Listener()
    browsers = [ServiceBrowser(zc, t, listener) for t in SERVICE_TYPES]
    last_push = 0.0
    last_err = ""
    try:
        while True:
            if listener.dirty or time.time() - last_push > 30:
                try:
                    push(list(listener.services.values()))
                    if listener.dirty:
                        n = len(listener.services)
                        print(f"{ts()}  pushed {n} camera(s) to emulator" if n else
                              f"{ts()}  no remote cameras on LAN yet (emulator list cleared)", flush=True)
                    listener.dirty = False
                    last_push = time.time()
                    last_err = ""
                except OSError as e:
                    msg = f"cannot reach relay in emulator ({e}); is the emulator running?"
                    if msg != last_err:
                        print(f"{ts()}  {msg}", flush=True)
                        last_err = msg
                    last_push = time.time() - 25  # retry in ~5 s
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        for b in browsers:
            b.cancel()
        zc.close()


if __name__ == "__main__":
    main()
