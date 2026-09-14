-- lib/truebrew.lua
-- Shared helper for the truebrew mise backend plugin.
-- Implements "Homebrew bottles without Homebrew", inspired by zerobrew:
--   formulae.brew.sh JSON API -> dep closure -> GHCR bottle (sha256) ->
--   extract to shared Cellar -> placeholder relocation -> opt link ->
--   per-tool mise shim in install_path.
--
-- Loaded from hooks via:
--   local tb = dofile(RUNTIME.pluginDirPath .. "/lib/truebrew.lua")

local http = require("http")
local json = require("json")
local cmd = require("cmd")
local file = require("file")
local log = require("log")

local M = {}

M.API_BASE = "https://formulae.brew.sh/api"
M.GHCR_TOKEN_URL = "https://ghcr.io/token"

-- ---------------------------------------------------------------------------
-- small utils
-- ---------------------------------------------------------------------------

function M.shquote(s)
    s = tostring(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.trim(s)
    local r = tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
    return r
end

function M.home()
    local h = os.getenv("HOME")
    if h and h ~= "" then
        return h
    end
    -- last resort: expand via shell
    local ok, out = pcall(cmd.exec, "printf %s \"$HOME\"")
    if ok and out and out ~= "" then
        return M.trim(out)
    end
    error("Cannot determine $HOME (needed for truebrew root)")
end

function M.join(...)
    return file.join_path(...)
end

-- ---------------------------------------------------------------------------
-- paths
-- ---------------------------------------------------------------------------
-- Layout (user-owned, no sudo, no /opt/homebrew):
--   $TRUEBREW_ROOT/prefix/Cellar/<name>/<keg_version>/...
--   $TRUEBREW_ROOT/prefix/opt/<name> -> ../Cellar/<name>/<keg_version>
--   $TRUEBREW_ROOT/cache/blobs/<sha256>.tar.gz
--   <mise install_path>/bin/* -> symlinks into the keg's bin
--   <mise install_path>/truebrew.json (receipt for the shim)

function M.paths(options)
    options = options or {}
    local root = options["root"] or options["truebrew_root"] or os.getenv("TRUEBREW_ROOT")
    if not root or root == "" then
        local xdg = os.getenv("XDG_DATA_HOME")
        if xdg and xdg ~= "" then
            root = M.join(xdg, "mise-truebrew")
        else
            root = M.join(M.home(), ".local", "share", "mise-truebrew")
        end
    end
    local prefix = M.join(root, "prefix")
    return {
        root = root,
        prefix = prefix,
        cellar = M.join(prefix, "Cellar"),
        opt = M.join(prefix, "opt"),
        cache_blobs = M.join(root, "cache", "blobs"),
        cache_meta = M.join(root, "cache", "meta"),
    }
end

function M.ensure_dirs(paths)
    for _, d in ipairs({ paths.prefix, paths.cellar, paths.opt, paths.cache_blobs, paths.cache_meta }) do
        if not file.exists(d) then
            local ok, err = pcall(cmd.exec, "mkdir -p " .. M.shquote(d))
            if not ok then
                error("truebrew: cannot create dir " .. d .. ": " .. tostring(err))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- http helpers (prefer non-raising try_* variants; fall back to raising ones)
-- ---------------------------------------------------------------------------

function M.http_get(url, headers)
    headers = headers or {}
    if http.try_get ~= nil then
        local resp, err = http.try_get({ url = url, headers = headers })
        if err ~= nil then
            error("truebrew: HTTP GET failed for " .. url .. ": " .. tostring(err))
        end
        return resp
    else
        return http.get({ url = url, headers = headers })
    end
end

function M.http_download(url, dest, headers)
    headers = headers or {}
    if http.try_download_file ~= nil then
        local ok, err = http.try_download_file({ url = url, headers = headers }, dest)
        if err ~= nil then
            error("truebrew: download failed for " .. url .. ": " .. tostring(err))
        end
        return
    elseif http.download_file ~= nil then
        local err = http.download_file({ url = url, headers = headers }, dest)
        if err ~= nil then
            error("truebrew: download failed for " .. url .. ": " .. tostring(err))
        end
        return
    else
        error("truebrew: no http download function available")
    end
end

function M.get_json(url)
    local resp = M.http_get(url, { ["User-Agent"] = "mise-truebrew/0.1.0", ["Accept"] = "application/json" })
    if resp.status_code == 404 then
        return nil, 404
    end
    if resp.status_code ~= 200 then
        error("truebrew: HTTP " .. tostring(resp.status_code) .. " fetching " .. url)
    end
    local ok, data = pcall(json.decode, resp.body)
    if not ok then
        error("truebrew: invalid JSON from " .. url .. ": " .. tostring(data))
    end
    return data, 200
end

-- ---------------------------------------------------------------------------
-- formulae API
-- ---------------------------------------------------------------------------

local formula_cache = {}

-- Normalize user input: strip tap prefix ("homebrew/core/wget" -> "wget").
function M.normalize_tool(tool)
    if not tool or tool == "" then
        error("truebrew: tool name is empty")
    end
    -- allow "homebrew/core/<name>" form
    local base = tool:match("^.+/(.+)$")
    if base and tool:find("/") then
        -- only strip known tap prefixes; otherwise keep as-is and let API 404
        if tool:match("^homebrew/core/") or tool:match("^.+/.+/.+$") == nil then
            tool = base
        elseif tool:match("^homebrew/core/") then
            tool = base
        end
    end
    return tool
end

function M.get_formula(tool)
    tool = M.normalize_tool(tool)
    if formula_cache[tool] then
        return formula_cache[tool]
    end
    local url = M.API_BASE .. "/formula/" .. tool .. ".json"
    local data, status = M.get_json(url)
    if data == nil and status == 404 then
        error(
            "truebrew: no Homebrew formula named '"
                .. tool
                .. "' (see https://formulae.brew.sh). "
                .. "Casks are not supported; only homebrew-core formulae."
        )
    end
    if type(data["versions"]) ~= "table" or not data["versions"]["stable"] then
        error("truebrew: formula '" .. tool .. "' has no stable version")
    end
    if data["disabled"] then
        error("truebrew: formula '" .. tool .. "' is disabled: " .. tostring(data["disable_reason"] or ""))
    end
    formula_cache[tool] = data
    return data
end

function M.stable_version(formula)
    return tostring(formula["versions"]["stable"])
end

-- Keg dir version: "<stable>" or "<stable>_<revision>" (matches Homebrew
-- PkgVersion#to_str; bottle rebuild numbers are ignored for the path).
function M.keg_version(formula)
    local stable = M.stable_version(formula)
    local rev = tonumber(formula["revision"] or 0) or 0
    if rev > 0 then
        return stable .. "_" .. tostring(rev)
    end
    return stable
end

-- Runtime (non-build, non-test) dependencies for the current platform.
-- Mirrors Homebrew semantics needed for bottles:
--   dependencies[] + Linux variations, minus uses_from_macos on macOS.
function M.runtime_deps(formula, os_name)
    local deps = {}
    local seen = {}
    local function add(list)
        if type(list) ~= "table" then
            return
        end
        for _, d in ipairs(list) do
            if type(d) == "string" and not seen[d] then
                seen[d] = true
                table.insert(deps, d)
            end
        end
    end
    add(formula["dependencies"])
    -- Linux: variations carry extra deps per arch (e.g. openssl on linux-only paths)
    if os_name == "linux" and type(formula["variations"]) == "table" then
        for _, v in pairs(formula["variations"]) do
            if type(v) == "table" then
                add(v["dependencies"])
            end
        end
    end
    if os_name == "darwin" then
        -- uses_from_macos entries are provided by macOS itself; filter them out.
        local sys = {}
        if type(formula["uses_from_macos"]) == "table" then
            for _, u in ipairs(formula["uses_from_macos"]) do
                if type(u) == "string" then
                    sys[u] = true
                elseif type(u) == "table" and u["name"] then
                    sys[u["name"]] = true
                end
            end
        end
        local filtered = {}
        for _, d in ipairs(deps) do
            if not sys[d] then
                table.insert(filtered, d)
            end
        end
        deps = filtered
    end
    return deps
end

-- ---------------------------------------------------------------------------
-- platform / bottle tag selection
-- ---------------------------------------------------------------------------

function M.current_os()
    local os_type = ""
    if RUNTIME ~= nil and RUNTIME.osType ~= nil then
        os_type = tostring(RUNTIME.osType):lower()
    end
    if os_type == "" then
        local ok, out = pcall(cmd.exec, "uname -s")
        if ok then
            out = M.trim(out):lower()
            if out:find("darwin") then
                os_type = "darwin"
            elseif out:find("linux") then
                os_type = "linux"
            else
                os_type = out
            end
        end
    end
    if os_type == "macos" or os_type == "osx" or os_type == "darwin" then
        return "darwin"
    elseif os_type == "linux" then
        return "linux"
    elseif os_type == "windows" or os_type == "win32" then
        return "windows"
    end
    return os_type
end

function M.current_arch()
    local arch = ""
    if RUNTIME ~= nil and RUNTIME.archType ~= nil then
        arch = tostring(RUNTIME.archType):lower()
    end
    if arch == "" then
        local ok, out = pcall(cmd.exec, "uname -m")
        if ok then
            arch = M.trim(out):lower()
        end
    end
    if arch == "arm64" or arch == "aarch64" then
        return "arm64"
    elseif arch == "amd64" or arch == "x86_64" or arch == "x64" then
        return "x86_64"
    end
    return arch
end

function M.macos_major()
    local ok, out = pcall(cmd.exec, "sw_vers -productVersion")
    if not ok or not out or M.trim(out) == "" then
        return nil
    end
    local ver = M.trim(out)
    -- "27.0", "26.1", "15.5", "14.2", "13.6", "12.7", "11.7", "10.15.7"
    local major, minor = ver:match("^(%d+)%.(%d+)")
    if major == "10" and minor then
        return 10 -- catalina/mojave era; treat uniformly
    end
    return tonumber(major)
end

-- Ordered newest-first arm64 macOS bottle tags known to Homebrew.
M.ARM64_MAC_TAGS = {
    { tag = "arm64_golden_gate", major = 27 },
    { tag = "arm64_tahoe", major = 26 },
    { tag = "arm64_sequoia", major = 15 },
    { tag = "arm64_sonoma", major = 14 },
    { tag = "arm64_ventura", major = 13 },
    { tag = "arm64_monterey", major = 12 },
    { tag = "arm64_big_sur", major = 11 },
}

-- Intel macOS tags use bare names (x86_64 implied).
M.X64_MAC_TAGS = {
    { tag = "sonoma", major = 14 },
    { tag = "ventura", major = 13 },
    { tag = "monterey", major = 12 },
    { tag = "big_sur", major = 11 },
    { tag = "catalina", major = 10 },
    { tag = "mojave", major = 10 },
}

function M.candidate_tags()
    local os_name = M.current_os()
    local arch = M.current_arch()
    if os_name == "windows" then
        error("truebrew: Windows is not supported (Homebrew bottles are macOS/Linux only)")
    end
    if os_name == "linux" then
        if arch == "arm64" then
            return { "arm64_linux", "all" }
        elseif arch == "x86_64" then
            return { "x86_64_linux", "all" }
        else
            error("truebrew: unsupported Linux arch '" .. arch .. "' (need arm64/x86_64)")
        end
    elseif os_name == "darwin" then
        local major = M.macos_major()
        local tags = {}
        if arch == "arm64" then
            for _, e in ipairs(M.ARM64_MAC_TAGS) do
                -- Never select a bottle built for a NEWER macOS than the host.
                if major == nil or e.major <= major then
                    table.insert(tags, e.tag)
                end
            end
            table.insert(tags, "all")
            if #tags == 1 then
                error("truebrew: macOS " .. tostring(major) .. " is older than all known bottle tags")
            end
            return tags
        elseif arch == "x86_64" then
            for _, e in ipairs(M.X64_MAC_TAGS) do
                if major == nil or e.major <= major then
                    table.insert(tags, e.tag)
                end
            end
            table.insert(tags, "all")
            return tags
        else
            error("truebrew: unsupported macOS arch '" .. arch .. "' (need arm64/x86_64)")
        end
    else
        error("truebrew: unsupported OS '" .. tostring(os_name) .. "' (need macOS/Linux)")
    end
end

function M.select_bottle(formula)
    local bottle = formula["bottle"]
    if type(bottle) ~= "table" or type(bottle["stable"]) ~= "table" then
        error("truebrew: formula '" .. tostring(formula["name"]) .. "' has no bottle (source-only)")
    end
    local files = bottle["stable"]["files"]
    if type(files) ~= "table" then
        error("truebrew: formula '" .. tostring(formula["name"]) .. "' has no bottled files")
    end
    local cands = M.candidate_tags()
    for _, tag in ipairs(cands) do
        local entry = files[tag]
        if type(entry) == "table" and entry["url"] and entry["sha256"] then
            return tag, entry
        end
    end
    error(
        "truebrew: no bottle for '"
            .. tostring(formula["name"])
            .. "' on "
            .. M.current_os()
            .. "/"
            .. M.current_arch()
            .. " (tried: "
            .. table.concat(cands, ", ")
            .. ")"
    )
end

-- ---------------------------------------------------------------------------
-- GHCR download + sha256
-- ---------------------------------------------------------------------------

function M.ghcr_repo_from_url(url)
    -- https://ghcr.io/v2/<repo>/blobs/<digest>
    local repo = tostring(url):match("^https?://ghcr%.io/v2/(.+)/blobs/.+$")
    if not repo then
        error("truebrew: unexpected bottle URL (not a ghcr.io blob URL): " .. tostring(url))
    end
    return repo
end

function M.ghcr_token(repo)
    local url = M.GHCR_TOKEN_URL .. "?scope=repository:" .. repo .. ":pull"
    local resp = M.http_get(url, { ["User-Agent"] = "mise-truebrew/0.1.0", ["Accept"] = "application/json" })
    if resp.status_code ~= 200 then
        error("truebrew: GHCR token request failed (HTTP " .. tostring(resp.status_code) .. ") for " .. repo)
    end
    local ok, data = pcall(json.decode, resp.body)
    if not ok or type(data) ~= "table" or not data["token"] then
        error("truebrew: invalid GHCR token response for " .. repo)
    end
    return data["token"]
end

function M.sha256_of(path)
    -- Try macOS `shasum`, then Linux `sha256sum`, then openssl.
    local attempts = {
        "shasum -a 256 " .. M.shquote(path),
        "sha256sum " .. M.shquote(path),
        "openssl dgst -sha256 " .. M.shquote(path),
    }
    local last_err = nil
    for _, c in ipairs(attempts) do
        local ok, out = pcall(cmd.exec, c)
        if ok and out then
            local hex = tostring(out):match("(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)")
            if hex then
                return hex:lower()
            end
            last_err = "unparseable checksum output: " .. tostring(out)
        else
            last_err = out
        end
    end
    error("truebrew: cannot compute sha256 (need shasum/sha256sum/openssl): " .. tostring(last_err))
end

function M.download_bottle(bottle_url, expected_sha256, dest)
    if file.exists(dest) then
        local actual = M.sha256_of(dest)
        if actual == expected_sha256:lower() then
            log.info("truebrew: cached bottle " .. dest)
            return
        end
        log.warn("truebrew: cached blob checksum mismatch, re-downloading " .. dest)
        pcall(cmd.exec, "rm -f " .. M.shquote(dest))
    end
    local repo = M.ghcr_repo_from_url(bottle_url)
    local token = M.ghcr_token(repo)
    log.info("truebrew: downloading bottle " .. bottle_url)
    M.http_download(bottle_url, dest, {
        ["User-Agent"] = "mise-truebrew/0.1.0",
        ["Accept"] = "application/octet-stream",
        ["Authorization"] = "Bearer " .. token,
    })
    local actual = M.sha256_of(dest)
    if actual ~= expected_sha256:lower() then
        pcall(cmd.exec, "rm -f " .. M.shquote(dest))
        error(
            "truebrew: sha256 mismatch for bottle (expected "
                .. expected_sha256
                .. ", got "
                .. actual
                .. "). Refusing to install."
        )
    end
end

-- ---------------------------------------------------------------------------
-- install: extract + relocate + link
-- ---------------------------------------------------------------------------

function M.keg_dir(paths, name, keg_ver)
    return M.join(paths.cellar, name, keg_ver)
end

function M.opt_link(paths, name)
    return M.join(paths.opt, name)
end

function M.is_regular_file(path)
    -- Regular file, not a symlink/dir (portable across mise file-module versions).
    local ok, _ = pcall(cmd.exec, "test -f " .. M.shquote(path) .. " && test ! -L " .. M.shquote(path))
    return ok
end

function M.is_file_like(path)
    -- True for regular files and symlinks-to-files; false for dirs/missing.
    local ok, _ = pcall(cmd.exec, "test -f " .. M.shquote(path))
    return ok
end

function M.dir_entries(dir)
    -- Bare entry names (no . / ..), sorted. Uses ls for compat with older
    -- mise runtimes that lack file.list.
    local ok, out = pcall(cmd.exec, "ls -A " .. M.shquote(dir))
    if not ok or not out then
        return {}
    end
    local t = {}
    for raw in tostring(out):gmatch("[^\n]+") do
        local e = M.trim(raw)
        if e ~= "" then
            table.insert(t, e)
        end
    end
    return t
end

function M.list_files_with_string(dir, needle)
    -- Returns newline-separated paths containing needle (may include binaries).
    local ok, out = pcall(
        cmd.exec,
        "grep -rl " .. M.shquote(needle) .. " " .. M.shquote(dir) .. " 2>/dev/null || true"
    )
    if not ok or not out or M.trim(out) == "" then
        return {}
    end
    local t = {}
    for raw in tostring(out):gmatch("[^\n]+") do
        local line = M.trim(raw)
        if line ~= "" then
            table.insert(t, line)
        end
    end
    return t
end

function M.is_macho(path)
    local ok, out = pcall(cmd.exec, "file " .. M.shquote(path))
    return ok and out and tostring(out):find("Mach%-O") ~= nil
end

function M.is_elf(path)
    local ok, out = pcall(cmd.exec, "file " .. M.shquote(path))
    return ok and out and tostring(out):find("ELF") ~= nil
end

function M.macho_refs(path)
    local ok, out = pcall(cmd.exec, "otool -L " .. M.shquote(path) .. " 2>/dev/null")
    if not ok or not out then
        return {}
    end
    local refs = {}
    for raw in tostring(out):gmatch("[^\n]+") do
        local lib = M.trim(raw):match("^(%S+) %(")
        if lib and lib:find("@@HOMEBREW") then
            table.insert(refs, lib)
        end
    end
    return refs
end

function M.macho_id(path)
    local ok, out = pcall(cmd.exec, "otool -D " .. M.shquote(path) .. " 2>/dev/null")
    if not ok or not out then
        return nil
    end
    local lines = {}
    for raw in tostring(out):gmatch("[^\n]+") do
        table.insert(lines, M.trim(raw))
    end
    if #lines >= 2 and lines[2]:find("@@HOMEBREW") then
        return lines[2]
    end
    return nil
end

function M.relocate_macho_file(path, prefix, cellar)
    local changed = false
    for _, old in ipairs(M.macho_refs(path)) do
        local new = old:gsub("@@HOMEBREW_PREFIX@@", prefix):gsub("@@HOMEBREW_CELLAR@@", cellar)
        if new ~= old then
            local ok, err = pcall(
                cmd.exec,
                "install_name_tool -change "
                    .. M.shquote(old)
                    .. " "
                    .. M.shquote(new)
                    .. " "
                    .. M.shquote(path)
            )
            if not ok then
                error("truebrew: install_name_tool -change failed for " .. path .. ": " .. tostring(err))
            end
            changed = true
        end
    end
    local id = M.macho_id(path)
    if id then
        local new_id = id:gsub("@@HOMEBREW_PREFIX@@", prefix):gsub("@@HOMEBREW_CELLAR@@", cellar)
        if new_id ~= id then
            local ok, err =
                pcall(cmd.exec, "install_name_tool -id " .. M.shquote(new_id) .. " " .. M.shquote(path))
            if not ok then
                error("truebrew: install_name_tool -id failed for " .. path .. ": " .. tostring(err))
            end
            changed = true
        end
    end
    return changed
end

function M.relocate_text_file(path, prefix, cellar)
    -- Only call on non-Mach-O/non-ELF regular files.
    local ok, err = pcall(cmd.exec, table.concat({
        "perl -pi -e",
        M.shquote("s|@@HOMEBREW_PREFIX@@|" .. prefix .. "|g; s|@@HOMEBREW_CELLAR@@|" .. cellar .. "|g"),
        M.shquote(path),
    }, " "))
    if not ok then
        error("truebrew: placeholder replacement failed for " .. path .. ": " .. tostring(err))
    end
    -- Also rewrite hardcoded build prefixes in text (scripts, pc files, cmake).
    -- Harmless when absent; restricted to text files so Mach-O is untouched.
    pcall(cmd.exec, table.concat({
        "perl -pi -e",
        M.shquote(
            "s|/opt/homebrew|"
                .. prefix
                .. "|g; s|/usr/local|"
                .. prefix
                .. "|g; s|/home/linuxbrew/.linuxbrew|"
                .. prefix
                .. "|g"
        ),
        M.shquote(path),
    }, " "))
end

function M.relocate_keg(keg_dir, prefix, cellar)
    local os_name = M.current_os()
    -- 1. Mach-O / ELF linkage pass (never text-patch binaries).
    local candidates = {}
    for _, needle in ipairs({ "@@HOMEBREW_PREFIX@@", "@@HOMEBREW_CELLAR@@" }) do
        for _, p in ipairs(M.list_files_with_string(keg_dir, needle)) do
            candidates[p] = true
        end
    end
    local macho_changed = {}
    for path, _ in pairs(candidates) do
        if M.is_regular_file(path) and M.is_macho(path) then
            if os_name ~= "darwin" then
                log.warn("truebrew: Mach-O file on non-macOS: " .. path)
            else
                local ok, res = pcall(M.relocate_macho_file, path, prefix, cellar)
                if not ok then
                    error(res)
                end
                if res then
                    macho_changed[#macho_changed + 1] = path
                end
            end
        end
    end
    -- 2. Text pass (scripts, pkgconfig, cmake, headers). Always runs,
    --    even for :any_skip_relocation-style bottles.
    local text_count = 0
    for path, _ in pairs(candidates) do
        if M.is_regular_file(path) and not M.is_macho(path) and not M.is_elf(path) then
            M.relocate_text_file(path, prefix, cellar)
            text_count = text_count + 1
        elseif M.is_regular_file(path) and M.is_elf(path) and os_name == "linux" then
            log.warn("truebrew: ELF file with placeholders needs patchelf review: " .. path)
        end
    end
    -- 3. Hardcoded build-prefix in text files (non-relocatable bottles).
    for _, needle in ipairs({ "/opt/homebrew/Cellar", "/home/linuxbrew/.linuxbrew/Cellar" }) do
        for _, path in ipairs(M.list_files_with_string(keg_dir, needle)) do
            if M.is_regular_file(path) and not M.is_macho(path) and not M.is_elf(path) then
                M.relocate_text_file(path, prefix, cellar)
                text_count = text_count + 1
            end
        end
    end
    -- 4. Relativize absolute symlinks pointing into the old Homebrew prefix.
    pcall(cmd.exec, table.concat({
        "find",
        M.shquote(keg_dir),
        "-type l -print0 | while IFS= read -r -d '' l; do",
        't="$(readlink "$l")";',
        'case "$t" in',
        "/opt/homebrew/*|/usr/local/Cellar/*|/usr/local/opt/*|/home/linuxbrew/.linuxbrew/*)",
        -- map old prefix -> new prefix, keep the remainder
        'n="'
            .. prefix
            .. '${t#/opt/homebrew}";',
        -- crude but safe: only rewrite when target exists under new prefix
        'if [ -e "$n" ]; then ln -sfn "$n" "$l"; fi;;',
        "esac; done",
    }, " "))
    -- 5. Re-sign everything we touched (arm64 macOS requires it).
    if os_name == "darwin" and #macho_changed > 0 then
        local parts = { "codesign -f -s -" }
        for _, p in ipairs(macho_changed) do
            table.insert(parts, M.shquote(p))
        end
        local ok, err = pcall(cmd.exec, table.concat(parts, " "))
        if not ok then
            error("truebrew: codesign failed: " .. tostring(err))
        end
    end
    log.info(
        "truebrew: relocated " .. keg_dir .. " (" .. #macho_changed .. " Mach-O, " .. text_count .. " text)"
    )
end

function M.write_keg_receipt(keg_dir, info)
    local receipt = M.join(keg_dir, ".truebrew.json")
    local ok, encoded = pcall(json.encode, info)
    if ok then
        -- file module has no documented write; use shell safely.
        pcall(cmd.exec, "rm -f " .. M.shquote(receipt))
        local tmp = receipt .. ".tmp"
        local fh = io.open(tmp, "w")
        if fh then
            fh:write(encoded)
            fh:close()
            pcall(cmd.exec, "mv " .. M.shquote(tmp) .. " " .. M.shquote(receipt))
        end
    end
    -- Minimal brew-compatible INSTALL_RECEIPT.json so `brew list` interoperates
    -- if the user ever points real Homebrew at this prefix.
    local tab = {
        poured_from_bottle = true,
        time = os.time(),
        source = { path = info.ruby_source_path, tap_git_head = info.tap_git_head },
        runtime_dependencies = info.runtime_dependencies or {},
        bottled = true,
    }
    local ok2, enc2 = pcall(json.encode, { source_modified_time = 0, HEAD = info.tap_git_head, stdlib = nil, compiler = nil, runtime_dependencies = tab.runtime_dependencies, poured_from_bottle = true, time = tab.time, source = tab.source })
    if ok2 then
        local dest = M.join(keg_dir, "INSTALL_RECEIPT.json")
        local fh2 = io.open(dest .. ".tmp", "w")
        if fh2 then
            fh2:write(enc2)
            fh2:close()
            pcall(cmd.exec, "mv " .. M.shquote(dest .. ".tmp") .. " " .. M.shquote(dest))
        end
    end
end

function M.read_keg_receipt(keg_dir)
    local p = M.join(keg_dir, ".truebrew.json")
    if not file.exists(p) then
        return nil
    end
    local ok, content = pcall(file.read, p)
    if not ok or not content then
        return nil
    end
    local ok2, data = pcall(json.decode, content)
    if ok2 then
        return data
    end
    return nil
end

function M.refresh_opt_link(paths, name, keg_ver)
    local link = M.opt_link(paths, name)
    local target = M.join("..", "Cellar", name, keg_ver)
    pcall(cmd.exec, "rm -f " .. M.shquote(link))
    local ok, err = pcall(cmd.exec, "ln -s " .. M.shquote(target) .. " " .. M.shquote(link))
    if not ok then
        error("truebrew: cannot link opt for " .. name .. ": " .. tostring(err))
    end
end

-- Install one formula's bottle into the shared Cellar (deps must already be
-- installed by the caller). Returns keg_dir.
function M.install_keg(name, formula, paths)
    local keg_ver = M.keg_version(formula)
    local keg_dir = M.keg_dir(paths, name, keg_ver)
    local tag, entry = M.select_bottle(formula)
    local url = entry["url"]
    local sha = tostring(entry["sha256"]):lower()

    local receipt = M.read_keg_receipt(keg_dir)
    if receipt and receipt["sha256"] == sha and file.exists(keg_dir) then
        log.info("truebrew: already installed " .. name .. " " .. keg_ver)
        M.refresh_opt_link(paths, name, keg_ver)
        return keg_dir
    end
    if file.exists(keg_dir) and receipt == nil then
        -- Foreign/partial dir: only reuse when it looks complete.
        if not file.exists(M.join(keg_dir, "INSTALL_RECEIPT.json")) then
            log.warn("truebrew: removing incomplete keg dir " .. keg_dir)
            pcall(cmd.exec, "rm -rf " .. M.shquote(keg_dir))
        end
    end

    M.ensure_dirs(paths)
    local blob = M.join(paths.cache_blobs, sha .. ".tar.gz")
    M.download_bottle(url, sha, blob)

    if not file.exists(keg_dir) then
        log.info("truebrew: pouring " .. name .. " " .. keg_ver .. " (" .. tag .. ")")
        local ok, err = pcall(cmd.exec, "tar -xzf " .. M.shquote(blob) .. " -C " .. M.shquote(paths.cellar))
        if not ok then
            error("truebrew: extraction failed for " .. name .. ": " .. tostring(err))
        end
        if not file.exists(keg_dir) then
            error(
                "truebrew: bottle for "
                    .. name
                    .. " did not contain expected keg "
                    .. name
                    .. "/"
                    .. keg_ver
            )
        end
        M.relocate_keg(keg_dir, paths.prefix, paths.cellar)
        M.write_keg_receipt(keg_dir, {
            name = name,
            keg_version = keg_ver,
            stable = M.stable_version(formula),
            bottle_tag = tag,
            bottle_url = url,
            sha256 = sha,
            prefix = paths.prefix,
            cellar = paths.cellar,
            ruby_source_path = formula["ruby_source_path"],
            tap_git_head = formula["tap_git_head"],
            runtime_dependencies = M.runtime_deps(formula, M.current_os()),
        })
    end
    M.refresh_opt_link(paths, name, keg_ver)
    return keg_dir
end

-- Install a formula + its runtime closure, deps-first. Returns main keg_dir.
function M.install_with_deps(name, paths, stack)
    stack = stack or {}
    if stack[name] then
        error("truebrew: dependency cycle detected at '" .. name .. "'")
    end
    stack[name] = true
    local formula = M.get_formula(name)
    local os_name = M.current_os()
    for _, dep in ipairs(M.runtime_deps(formula, os_name)) do
        M.install_with_deps(dep, paths, stack)
    end
    stack[name] = nil
    return M.install_keg(formula["name"] or name, formula, paths)
end

-- ---------------------------------------------------------------------------
-- mise shim (install_path)
-- ---------------------------------------------------------------------------

function M.write_shim(install_path, keg_dir, meta)
    pcall(cmd.exec, "mkdir -p " .. M.shquote(M.join(install_path, "bin")))
    -- Link keg executables (bin + sbin) into the shim.
    for _, sub in ipairs({ "bin", "sbin" }) do
        local src_dir = M.join(keg_dir, sub)
        if file.exists(src_dir) then
            for _, base in ipairs(M.dir_entries(src_dir)) do
                local src = M.join(src_dir, base)
                local dest = M.join(install_path, "bin", base)
                if M.is_file_like(src) then
                    pcall(cmd.exec, "rm -f " .. M.shquote(dest))
                    local ok2, err2 =
                        pcall(cmd.exec, "ln -s " .. M.shquote(src) .. " " .. M.shquote(dest))
                    if not ok2 then
                        error("truebrew: cannot link " .. base .. ": " .. tostring(err2))
                    end
                end
            end
        end
    end
    local receipt_path = M.join(install_path, "truebrew.json")
    local ok, encoded = pcall(json.encode, meta)
    if ok then
        local fh = io.open(receipt_path .. ".tmp", "w")
        if fh then
            fh:write(encoded)
            fh:close()
            pcall(cmd.exec, "mv " .. M.shquote(receipt_path .. ".tmp") .. " " .. M.shquote(receipt_path))
        end
    end
end

function M.shim_bins(install_path)
    local d = M.join(install_path, "bin")
    if not file.exists(d) then
        return {}
    end
    return M.dir_entries(d)
end

return M
