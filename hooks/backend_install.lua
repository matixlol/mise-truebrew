--- hooks/backend_install.lua
--- Installs a Homebrew formula bottle without Homebrew.
--- Documentation: https://mise.jdx.dev/backend-plugin-development.html

local function load_helper()
    if RUNTIME ~= nil and RUNTIME.pluginDirPath ~= nil then
        return dofile(RUNTIME.pluginDirPath .. "/lib/truebrew.lua")
    end
    return dofile("./lib/truebrew.lua")
end

function PLUGIN:BackendInstall(ctx)
    local tb = load_helper()
    local cmd = require("cmd")
    local file = require("file")
    local log = require("log")

    local tool = ctx.tool
    local version = tostring(ctx.version or "")
    local install_path = ctx.install_path
    if not tool or tool == "" then
        error("truebrew: tool name is empty")
    end
    if version == "" then
        error("truebrew: version is empty")
    end
    if not install_path or install_path == "" then
        error("truebrew: install_path is empty")
    end
    if version == "latest" then
        -- mise usually resolves this via list-versions first; handle it anyway.
        local f = tb.get_formula(tool)
        version = tb.stable_version(f)
        log.info("truebrew: resolved 'latest' to " .. version)
    end

    local paths = tb.paths(ctx.options)
    tb.ensure_dirs(paths)

    -- Resolve formula; allow reinstalling an already-poured keg even when it
    -- is no longer stable (downgrade/relink path).
    local formula = tb.get_formula(tool)
    local stable = tb.stable_version(formula)
    local keg_ver = tb.keg_version(formula)
    local requested_keg = tb.keg_dir(paths, formula["name"] or tool, version)

    if version ~= stable then
        -- Revision-suffixed request ("1.2.3_1") may still match current keg.
        if version == keg_ver then
            log.info("truebrew: installing current keg " .. version .. " (stable " .. stable .. ")")
        elseif file.exists(requested_keg) then
            log.info("truebrew: linking previously poured " .. tool .. " " .. version)
            tb.refresh_opt_link(paths, formula["name"] or tool, version)
            tb.write_shim(install_path, requested_keg, {
                name = formula["name"] or tool,
                version = version,
                keg_dir = requested_keg,
                prefix = paths.prefix,
                relinked = true,
            })
            return {}
        else
            error(
                "truebrew: only the current stable version is installable for '"
                    .. tool
                    .. "' (stable: "
                    .. stable
                    .. ", requested: "
                    .. version
                    .. "). Homebrew removes old bottles."
            )
        end
    end

    local keg_dir = tb.install_with_deps(formula["name"] or tool, paths)

    -- Shim this specific keg into mise's install_path.
    pcall(cmd.exec, "mkdir -p " .. tb.shquote(install_path))
    tb.write_shim(install_path, keg_dir, {
        name = formula["name"] or tool,
        version = version,
        stable = stable,
        keg_version = tb.keg_version(formula),
        keg_dir = keg_dir,
        prefix = paths.prefix,
        cellar = paths.cellar,
    })

    local bins = tb.shim_bins(install_path)
    if #bins == 0 then
        log.warn(
            "truebrew: '"
                .. tool
                .. "' poured but exposes no bin/ executables (library-only formula?). "
                .. "Use its lib/ via LDFLAGS/CPPFLAGS from BackendExecEnv."
        )
    else
        log.info("truebrew: installed " .. tool .. "@" .. version .. " (" .. table.concat(bins, ", ") .. ")")
    end
    return {}
end
