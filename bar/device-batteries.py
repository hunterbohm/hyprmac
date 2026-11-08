#!/usr/bin/python3 -I
"""Put the battery level of your iPhone (and any iPad) into OmniWM's bar.

A login agent runs this every minute. It reads phones that sync with this Mac over Wi-Fi, using
libimobiledevice, and hands the result to the bar's battery panel with `omniwmctl shell set`.
It only talks to phones this Mac already trusts, so it never makes a "Trust This Computer?"
prompt appear. A phone shows up on Wi-Fi only now and then while it sleeps, so the last reading
is kept with its time.
"""
import json
import os
import plistlib
import socket
import struct
import subprocess
import time

BREW = "/opt/homebrew/bin"
STATE = os.path.expanduser("~/.local/state/hyprmac/device-batteries.json")
VAR = "hyprmac_devices"
FORGET_AFTER = 24 * 3600


def run(*args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def trusted(udid):
    """True when macOS holds a pairing record for this phone (asking usbmuxd, like Finder does)."""
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(5)
        s.connect("/var/run/usbmuxd")
        body = plistlib.dumps({"MessageType": "ReadPairRecord", "PairRecordID": udid,
                               "ClientVersionString": "hyprmac", "ProgName": "hyprmac"})
        s.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, 1) + body)
        size = struct.unpack("<IIII", s.recv(16))[0] - 16
        data = b""
        while len(data) < size:
            chunk = s.recv(size - len(data))
            if not chunk:
                break
            data += chunk
        return "PairRecordData" in plistlib.loads(data)
    except (OSError, ValueError, struct.error, plistlib.InvalidFileException):
        return False


def fields(text):
    out = {}
    for line in text.splitlines():
        key, sep, value = line.partition(": ")
        if sep:
            out[key.strip()] = value.strip()
    return out


def main():
    try:
        with open(STATE) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}

    def read(udid):
        info = fields(run(f"{BREW}/ideviceinfo", "-n", "-u", udid, "-q", "com.apple.mobile.battery"))
        if not info.get("BatteryCurrentCapacity", "").isdigit():
            return False
        entry = cache.get(udid) or {}
        if "name" not in entry:
            about = fields(run(f"{BREW}/ideviceinfo", "-n", "-u", udid))
            entry["name"] = about.get("DeviceName") or "iPhone"
            entry["kind"] = "tablet" if about.get("DeviceClass") == "iPad" else "phone"
        entry["level"] = int(info["BatteryCurrentCapacity"])
        entry["charging"] = info.get("BatteryIsCharging") == "true"
        entry["full"] = info.get("FullyCharged") == "true"
        entry["updated"] = int(time.time())
        cache[udid] = entry
        return True

    # A sleeping phone drops off Wi-Fi for a few seconds at a time, so keep trying for a while.
    done, skipped = set(), set()
    deadline = time.time() + 20
    while time.time() < deadline:
        waiting = set(run(f"{BREW}/idevice_id", "-n").split()) - done - skipped
        for udid in waiting:
            if not trusted(udid):
                skipped.add(udid)
            elif read(udid):
                done.add(udid)
        if done and not waiting:
            break
        time.sleep(1)

    now = time.time()
    cache = {k: v for k, v in cache.items() if now - v.get("updated", 0) < FORGET_AFTER}
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE + ".tmp", "w") as f:
        json.dump(cache, f)
    os.replace(STATE + ".tmp", STATE)

    devices = sorted(cache.values(), key=lambda d: d["name"].lower())
    if devices:
        run(f"{BREW}/omniwmctl", "shell", "set", VAR, json.dumps(devices, separators=(",", ":")))


if __name__ == "__main__":
    main()
