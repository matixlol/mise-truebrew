--- hooks/backend_exec_env.lua
--- Sets PATH and build flags for a truebrew-installed formula.

local function load_helper()
    if RUNTIME ~= nil and RUNTIME.pluginDirPath ~= nil then
        return dofile(RUNTIME.pluginDirPath .. "/lib/truebrew.lua")
    end
    return dofile("./lib/truebrew.lua")
end

function PLUGIN:BackendExecEnv(ctx)
    local tb = load_helper()
    local file = require("file")

    local install_path = ctx.install_path
    local paths = tb.paths(ctx.options)
    local vars = {}

    local function add(key, value)
        table.insert(vars, { key = key, value = value })
    end

    -- Main binaries first.
    add("PATH", tb.join(install_path, "bin"))
    -- Shared prefix for dependency auxiliaries (e.g. `openssl` CLI next to libs).
    add("PATH", tb.join(paths.prefix, "bin"))

    -- keg opt dir (e.g. .../opt/openssl@3) for formulae that need their prefix.
    if ctx.tool and ctx.tool ~= "" then
        local opt = tb.join(paths.opt, ctx.tool)
        -- expose as <TOOL>_PREFIX? keep generic: TRUEBREW_OPT_<name>
        local flat = tostring(ctx.tool):upper():gsub("[^A-Z0-9]", "_")
        add("TRUEBREW_OPT_" .. flat, opt)
    end

    -- Compiler / linker flags so keg-only libraries (openssl, readline, ...)
    -- are usable from mise-managed toolchains.
    add("LDFLAGS", "-L" .. tb.join(paths.prefix, "lib"))
    add("CPPFLAGS", "-I" .. tb.join(paths.prefix, "include"))
    add("PKG_CONFIG_PATH", tb.join(paths.prefix, "lib", "pkgconfig"))
    add("PKG_CONFIG_PATH", tb.join(paths.prefix, "share", "pkgconfig"))
    add("MANPATH", tb.join(paths.prefix, "share", "man"))

    -- Linux dynamic loader fallback for any ELF RPATH we could not rewrite.
    if tb.current_os() == "linux" then
        add("LD_LIBRARY_PATH", tb.join(paths.prefix, "lib"))
    end

    -- Drop entries whose dirs do not exist to keep env clean.
    local out = {}
    for _, e in ipairs(vars) do
        if e.key == "PATH" or e.key == "MANPATH" or e.key == "PKG_CONFIG_PATH" or e.key == "LD_LIBRARY_PATH" then
            if file.exists(e.value) then
                table.insert(out, e)
            end
        else
            table.insert(out, e)
        end
    end
    return { env_vars = out }
end
