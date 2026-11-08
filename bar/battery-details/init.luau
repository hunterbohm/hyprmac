-- SPDX-License-Identifier: GPL-2.0-only
-- Based on OmniWM's battery-details widget, copyright (C) 2026 OmniNull (https://github.com/OmniNull/OmniWM).
-- HyprMac adds a Devices section to the panel, like Apple's Batteries widget: your iPhone (read over
-- Wi-Fi by HyprMac's device-batteries job, handed over as the `hyprmac_devices` value) and Bluetooth
-- devices such as AirPods, keyboard and mouse.

local look = require("../lib/look")
local battery = require("../lib/battery")
local actions = require("../lib/actions")

local SYMBOLS = {
    phone = "iphone",
    tablet = "ipad",
    headphones = "airpods",
    keyboard = "keyboard",
    mouse = "magicmouse",
    gamepad = "gamecontroller",
    computer = "laptopcomputer",
}

function render(ctx)
    local state = battery.state(ctx)
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local behaviour = { onClick = ui.popout, help = state.percent }
    local button = look.batteryDetailsBar and look.batteryDetailsBar(ctx, state)
    if not button then
        local scale = look.scale(ctx)
        local props = table.clone(behaviour)
        if ctx.data.bar.style.vertical then
            props.gap = scale
            props.pad = 2 * scale
            props[#props + 1] = battery.cell(state, 17 * scale, 10 * scale)
            props[#props + 1] = look.text{ text = state.text, size = 10 * scale }
        elseif state.mode == "inside" then
            props[#props + 1] = battery.cell(state, 30 * scale, 15 * scale, state.text)
        else
            props[#props + 1] = battery.cell(state, 23 * scale, 12 * scale)
            if state.mode == "beside" then
                props[#props + 1] = look.text{ text = state.percent, size = 13 * scale, reserve = state.reserve }
            end
        end
        button = look.bar(ctx, props)
    end
    for key, value in behaviour do
        button[key] = value
    end
    return button
end

local function since(ctx, updated: number): string?
    local minutes = (ctx.data.seconds - updated) // 60
    if minutes < 3 then
        return nil
    elseif minutes < 60 then
        return string.format("%d min ago", minutes)
    end
    return string.format("%d h ago", minutes // 60)
end

-- Phones from the device-batteries job, then connected Bluetooth devices that report a battery.
local function devices(ctx)
    local list = {}
    local raw = ctx.data.vars and ctx.data.vars.hyprmac_devices
    local phones = if raw then json.decode(raw) else nil
    if type(phones) == "table" then
        for _, d in phones do
            if type(d) == "table" and type(d.level) == "number" and type(d.name) == "string" then
                local age = if type(d.updated) == "number" then since(ctx, d.updated) else nil
                list[#list + 1] = { name = d.name, symbol = SYMBOLS[d.kind] or "iphone", level = d.level,
                    charging = d.charging == true, status = if d.full then omniwm.l10n("Fully charged")
                        elseif d.charging then omniwm.l10n("Charging")
                        elseif age then age
                        else nil }
            end
        end
    end
    local bt = ctx.data.bluetooth
    if bt and bt.power then
        for _, d in bt.devices or {} do
            if d.connected then
                local parts = {}
                if d.left then parts[#parts + 1] = "L " .. ctx.format.percent(d.left / 100) end
                if d.right then parts[#parts + 1] = "R " .. ctx.format.percent(d.right / 100) end
                if d.case then parts[#parts + 1] = omniwm.l10n("Case") .. " " .. ctx.format.percent(d.case / 100) end
                local level = d.battery
                if not level and (d.left or d.right) then
                    level = math.min(d.left or 100, d.right or 100)
                end
                level = level or d.case
                if level then
                    list[#list + 1] = { name = d.name, symbol = SYMBOLS[d.kind] or "dot.radiowaves.left.and.right",
                        level = level, status = if #parts > 0 then table.concat(parts, "  ") else nil }
                end
            end
        end
    end
    return list
end

local function cell(level: number, color: string)
    return ui.row{ gap = 1,
        ui.stack{ w = 20, h = 10, radius = 3, border = "foreground/0.45", borderWidth = 1,
            ui.box{ align = "leading", dx = 2, w = math.max(1.5, 16 * level / 100), h = 6, radius = 1.5, fill = color } },
        ui.box{ w = 1.5, h = 4, radius = 0.75, fill = "foreground/0.45" } }
end

local function deviceRow(ctx, d, width: number)
    local color = if d.charging then "success" elseif d.level <= 20 then "error" else "foreground"
    local text = { gap = 2, center = false, grow = 1,
        look.text{ text = d.name, size = 13, weight = "medium", maxWidth = width - 130 } }
    if d.status then
        text[#text + 1] = look.text{ text = d.status, size = 11, color = "secondaryForeground", maxWidth = width - 130 }
    end
    return ui.row{ w = width - 24, gap = 8, pad = 2,
        ui.stack{ w = 30, h = 30, radius = look.radius(15), fill = "foreground/0.08",
            look.glyph{ name = d.symbol, w = 15, h = 15, color = "foreground" } },
        ui.column(text),
        look.text{ text = ctx.format.percent(d.level / 100), size = 12, weight = "medium", color = color, maxWidth = 44 },
        cell(d.level, if color == "foreground" then "foreground/0.75" else color) }
end

function popout(ctx)
    local m = battery.model(ctx)
    if look.batteryPanel then
        return look.batteryPanel(ctx, m)
    end
    local width = look.width
    local panel = { w = width + 28, look.heading(omniwm.l10n("Battery"), width), battery.content(ctx, nil, m) }
    local list = devices(ctx)
    if #list > 0 then
        local group = { w = width }
        for _, d in list do
            group[#group + 1] = deviceRow(ctx, d, width)
        end
        panel[#panel + 1] = look.heading(omniwm.l10n("Devices"), width)
        panel[#panel + 1] = look.group(group)
    end
    local bt = ctx.data.bluetooth
    if bt and bt.access ~= "granted" then
        panel[#panel + 1] = actions.row("lock.fill", "Allow Bluetooth to show AirPods and keyboard",
            "bluetooth authorize", width, true)
    end
    return look.panel(ctx, panel)
end
