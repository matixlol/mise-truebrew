--- hooks/backend_list_versions.lua
--- Lists available versions for a Homebrew formula.
--- Homebrew only keeps the current stable bottle, so this returns one entry.
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html

local function load_helper()
    if RUNTIME ~= nil and RUNTIME.pluginDirPath ~= nil then
        return dofile(RUNTIME.pluginDirPath .. "/lib/truebrew.lua")
    end
    return dofile("./lib/truebrew.lua")
end

function PLUGIN:BackendListVersions(ctx)
    local tb = load_helper()
    local tool = ctx.tool
    if not tool or tool == "" then
        error("truebrew: tool name is empty")
    end
    local formula = tb.get_formula(tool)
    -- Oldest-to-newest per backend plugin contract; single stable entry.
    return { versions = { tb.stable_version(formula) } }
end
