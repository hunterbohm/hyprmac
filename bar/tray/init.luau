-- HyprMac tray: your menu bar apps (Tailscale, CleanShot, Bitwarden...) inside OmniWM's bar.
-- HyprMac lists them as the `hyprmac_tray` value. Clicking one opens hyprmac://tray/<id>, and HyprMac
-- opens that app's real menu bar menu.

local look = require("../lib/look")

local function items(ctx)
    local raw = ctx.data.vars and ctx.data.vars.hyprmac_tray
    local list = if raw then json.decode(raw) else nil
    return if type(list) == "table" then list else {}
end

function render(ctx)
    local list = items(ctx)
    if #list == 0 then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = look.scale(ctx)
    local size = 16 * scale
    local cell = math.max(22 * scale, ctx.data.bar.style.height - 10)
    local row = { gap = 0 }
    for _, item in list do
        if type(item) == "table" and type(item.id) == "string" and type(item.bundle) == "string" then
            local id = item.id
            row[#row + 1] = ui.stack{ key = id, w = cell, h = cell, radius = look.radius(6), hover = look.hover,
                help = if item.title and item.title ~= item.name then item.name .. ": " .. item.title else item.name,
                onClick = function()
                    omniwm.open("hyprmac://tray/" .. id)
                end,
                ui.icon{ app = item.bundle, w = size, h = size, placeholder = "app.dashed" } }
        end
    end
    return look.bar(ctx, row)
end
