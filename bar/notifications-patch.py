#!/usr/bin/env python3
"""Make Clear All and x in OmniWM's notifications panel work on macOS 26.

usage: notifications-patch.py <widgets/notifications/init.luau from `omniwmctl shell eject notifications`>

OmniWM clears notifications through com.apple.MenuBarAgent, which macOS 26 doesn't have, so its Clear All
and x buttons fail there with "Notification Center is unavailable". Doing the same through Notification
Center's own panel flashes that panel open and misses notifications it doesn't list. So this edits OmniWM's
own widget, copied into your config by OmniWM's eject command, to hide cleared notifications in the bar
only: Clear All and x keep their ids in the widget's store, which outlasts OmniWM restarts, and the panel and
the bell's count leave them out. macOS's Notification Center keeps its own copy. It also adds a trigger
HyprMac fires when the notification database changes, so the panel re-reads.
Exits 1, changing nothing, when the widget no longer has the lines this expects.
"""
import sys

MARK = "-- HyprMac:"

HELPER = """local function consume() end

-- HyprMac: macOS 26 gives OmniWM no way to clear notifications, so Clear All and x hide them in this panel
-- (bar/notifications-patch.py). Their ids stay in the widget's store, which outlasts restarts.
local HIDDEN = "hyprmacHidden"

local function hyprmacHidden()
    local ok, ids = pcall(omniwm.store.get, HIDDEN)
    local set = {}
    if ok and type(ids) == "table" then
        for _, id in ids do set[id] = true end
    end
    return set
end

local function hyprmacHide(value, items)
    return function(next)
        local hidden = hyprmacHidden()
        for _, item in items do hidden[string.lower(item.id)] = true end
        -- Forget notifications macOS no longer keeps, so the stored list stays short.
        local kept = {}
        if value and value.membershipComplete then
            for _, item in value.items or {} do
                local id = string.lower(item.id)
                if hidden[id] then kept[#kept + 1] = id end
            end
        else
            for id in hidden do kept[#kept + 1] = id end
        end
        omniwm.store.set(HIDDEN, kept)
        next.state.hyprmacHidden = #kept
        omniwm.run("notifications refresh")
    end
end
"""

# OmniWM's list, without the notifications hidden above. The bell's count uses it too.
VISIBLE = """local function omniVisibleItems(value)"""

FILTER = """local function visibleItems(value)
    local hidden = hyprmacHidden()
    local items = {}
    for _, item in omniVisibleItems(value) do
        if not hidden[string.lower(item.id)] then items[#items + 1] = item end
    end
    return items
end

local function canDismiss(value)"""

SUPPORTED = """local function allSourcesSupported(value)
    for _, item in visibleItems(value) do
        if not item.actionsSupported then return false end
    end
    return true
end"""

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
    ("local function visibleItems(value)", VISIBLE),
    ("local function canDismiss(value)", FILTER),
    (SUPPORTED, "-- HyprMac: any notification can be hidden here, whichever app sent it.\n"
                "local function allSourcesSupported(_)\n    return true\nend"),
    ('button("×", if canDismiss(value) and item.actionsSupported and not busy\n'
     '            then "notifications dismiss " .. item.bundle .. " " .. id else nil) }',
     'button("×", hyprmacHide(value, { item })) }'),
    ('if canDismiss(value) and allSourcesSupported(value) and #items > 0 and not busy\n'
     '                    then "notifications dismiss-all" else nil),',
     'if #items > 0 then hyprmacHide(value, items) else nil),'),
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
