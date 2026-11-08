#!/usr/bin/env python3
"""Point OmniWM's notifications panel at HyprMac for clearing.

usage: notifications-patch.py <widgets/notifications/init.luau from `omniwmctl shell eject notifications`>

OmniWM clears notifications through com.apple.MenuBarAgent, which macOS 26 doesn't have, so its Clear All
and x buttons fail there with "Notification Center is unavailable". This edits OmniWM's own widget, copied
into your config by OmniWM's eject command, so those two buttons open HyprMac's link (the
`hyprmac_notifications` value) instead, and adds a trigger HyprMac fires afterwards so the panel re-reads.
When HyprMac isn't running the buttons keep OmniWM's own action.
Exits 1, changing nothing, when the widget no longer has the lines this expects.
"""
import sys

MARK = "-- HyprMac:"

HELPER = """local function consume() end

-- HyprMac: on macOS 26 OmniWM can't reach Notification Center to clear, so HyprMac does it (bar/notifications-patch.py).
local function hyprmacClear(ctx, path, fallback)
    local base = ctx.data.vars and ctx.data.vars.hyprmac_notifications
    if type(base) ~= "string" or base == "" then return fallback end
    return function() omniwm.open(base .. "/" .. path) end
end
"""

# OmniWM is meant to re-read notifications when their database changes, but its file watch misses the
# changes on macOS 26, so HyprMac watches the database and runs
# `omniwmctl shell trigger notifications hyprmac-refresh`, and the panel re-reads.
TRIGGER = """
-- HyprMac: re-read notifications when HyprMac sees them change.
function trigger(_, event)
    if event.name == "hyprmac-refresh" then omniwm.run("notifications refresh") end
end
"""

EDITS = [
    ("local function consume() end\n", HELPER),
    ('then "notifications dismiss " .. item.bundle .. " " .. id else nil)',
     'then hyprmacClear(ctx, "dismiss/" .. id, "notifications dismiss " .. item.bundle .. " " .. id) else nil)'),
    ('then "notifications dismiss-all" else nil)',
     'then hyprmacClear(ctx, "dismiss-all", "notifications dismiss-all") else nil)'),
]


def main(path: str) -> int:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if MARK in text:
        return 0
    if "function trigger(" in text:
        print(f"notifications-patch: {path} already has a trigger function", file=sys.stderr)
        return 1
    for old, new in EDITS:
        if text.count(old) != 1:
            print(f"notifications-patch: expected one {old.strip()[:60]!r} in {path}", file=sys.stderr)
            return 1
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.rstrip("\n") + "\n" + TRIGGER)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]) if len(sys.argv) == 2 else 2)
