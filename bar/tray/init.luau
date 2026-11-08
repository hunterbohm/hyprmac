-- HyprMac tray: your menu bar apps (Tailscale, CleanShot, Bitwarden...) inside OmniWM's bar.
-- HyprMac lists them as the `hyprmac_tray` value, each with its click link (it carries a token only the
-- bar gets). Opening that link makes HyprMac open the app's real menu bar menu.
-- Like Omarchy's tray, apps you pin stay in the bar and the rest wait in a drawer behind an arrow, which
-- slides open while the pointer is on it. Right-click an icon to pin it or put it back in the drawer. Pins
-- live in the widget's store, which outlasts OmniWM restarts; new apps start in the drawer.

local look = require("../lib/look")

local PINS = "pinned"
local CLOSE_AFTER = 0.8 -- seconds the drawer stays open after the pointer leaves it
local MOTION = { response = 0.32, bounce = 0.08 }

local function items(ctx)
    local raw = ctx.data.vars and ctx.data.vars.hyprmac_tray
    local list = if raw then json.decode(raw) else nil
    return if type(list) == "table" then list else {}
end

local function pins()
    local ok, ids = pcall(omniwm.store.get, PINS)
    local set = {}
    if ok and type(ids) == "table" then
        for _, id in ids do
            if type(id) == "string" then set[id] = true end
        end
    end
    return set
end

local function togglePin(id)
    return function(ctx)
        local set = pins()
        set[id] = if set[id] then nil else true
        local list = {}
        for pinned in set do list[#list + 1] = pinned end
        table.sort(list)
        local ok, err = omniwm.store.set(PINS, list)
        if not ok and err then omniwm.log("HyprMac tray could not save pins: " .. tostring(err)) end
        ctx.state.revision = (ctx.state.revision or 0) + 1
    end
end

local function cancel(state)
    if state.timer then
        state.timer:cancel()
        state.timer = nil
    end
end

local function hover(ctx, event)
    local state = ctx.state
    if event.phase == "began" then
        cancel(state)
        state.open = true
    elseif event.phase == "ended" then
        cancel(state)
        local timer = omniwm.after(CLOSE_AFTER, function()
            state.timer = nil
            state.open = false
        end)
        state.timer = timer
        if not timer then state.open = false end
    end
end

-- Pointing at the arrow already opens the drawer, so clicking it only keeps it open (a toggle would shut
-- it under the pointer).
local function keepOpen(ctx)
    cancel(ctx.state)
    ctx.state.open = true
end

local function icon(item, pinned, cell, size)
    local link = if type(item.url) == "string" then item.url else "hyprmac://tray/" .. item.id
    local name = if type(item.title) == "string" and item.title ~= "" and item.title ~= item.name
        then item.name .. ": " .. item.title else item.name
    return ui.stack{ key = item.id, w = cell, h = cell, radius = look.radius(6), hover = look.hover,
        help = name .. (if pinned then " (right-click to move it into the drawer)" else " (right-click to pin it)"),
        appear = { opacity = 0, dx = 8, animate = MOTION },
        exit = { opacity = 0, dx = 8, animate = 0.12 },
        onClick = function()
            omniwm.open(link)
        end,
        onRightClick = togglePin(item.id),
        ui.icon{ app = item.bundle, w = size, h = size, placeholder = "app.dashed" } }
end

function render(ctx)
    local pinned = pins()
    local front, drawer = {}, {}
    for _, item in items(ctx) do
        if type(item) == "table" and type(item.id) == "string" and type(item.bundle) == "string" then
            if type(item.name) ~= "string" then item.name = item.bundle end
            if pinned[item.id] then front[#front + 1] = item else drawer[#drawer + 1] = item end
        end
    end
    if #front == 0 and #drawer == 0 then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = look.scale(ctx)
    local size = 16 * scale
    local cell = math.max(22 * scale, ctx.data.bar.style.height - 10)
    local row = { gap = 0 }
    -- The drawer opens to the left of the arrow, so the arrow and the pinned apps stay put.
    if #drawer > 0 then
        local open = ctx.state.open == true
        local group = { key = "drawer", gap = 0, animate = MOTION, onHover = hover }
        if open then
            for _, item in drawer do group[#group + 1] = icon(item, false, cell, size) end
        end
        group[#group + 1] = ui.stack{ key = "arrow", w = math.max(14 * scale, cell * 0.6), h = cell,
            radius = look.radius(6), hover = look.hover,
            help = if open then "Right-click an app to pin it" else #drawer .. " more menu bar apps",
            onClick = keepOpen,
            look.glyph{ name = if open then "chevron.right" else "chevron.left", size = 10 * scale,
                weight = "semibold", color = "secondaryForeground" } }
        row[#row + 1] = ui.row(group)
    end
    for _, item in front do row[#row + 1] = icon(item, true, cell, size) end
    return look.bar(ctx, row)
end
