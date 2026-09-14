--- hooks/backend_search_tools.lua
--- Query-driven search over homebrew-core formulae.
--- Strategy: exact formula lookup first (fast), then substring filter over
--- the full formulae index (31MB, cached per-query by mise).

local function load_helper()
    if RUNTIME ~= nil and RUNTIME.pluginDirPath ~= nil then
        return dofile(RUNTIME.pluginDirPath .. "/lib/truebrew.lua")
    end
    return dofile("./lib/truebrew.lua")
end

function PLUGIN:BackendSearchTools(ctx)
    local tb = load_helper()
    local log = require("log")
    local q = (ctx.query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then
        return { tools = {} }
    end

    -- 1. Exact match: single small JSON, no index download.
    local ok, formula = pcall(tb.get_formula, q)
    if ok and formula and formula["name"] then
        return {
            tools = {
                { name = formula["name"], description = formula["desc"] or "" },
            },
        }
    end

    -- 2. Substring search over the full index.
    log.info("truebrew: searching formulae index for '" .. q .. "' (one-time ~30MB download)")
    local data = tb.get_json(tb.API_BASE .. "/formula.json")
    if type(data) ~= "table" then
        return { tools = {} }
    end
    local out = {}
    for _, f in ipairs(data) do
        if type(f) == "table" and f["name"] then
            local name = tostring(f["name"]):lower()
            local desc = tostring(f["desc"] or ""):lower()
            if name:find(q, 1, true) or desc:find(q, 1, true) then
                table.insert(out, { name = f["name"], description = f["desc"] or "" })
                if #out >= 50 then
                    break
                end
            end
        end
    end
    return { tools = out }
end
