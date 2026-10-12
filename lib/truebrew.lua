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

-- mise caches search results per query, but the source index must be shared
-- across queries/processes. Keep only the fields used by search on disk.
M.FORMULA_INDEX_TTL = 24 * 60 * 60

local function valid_formula_index(data)
    if type(data) ~= "table" or #data == 0 then
        return false
    end
    for _, formula in ipairs(data) do
        if type(formula) ~= "table" or type(formula.name) ~= "string" then
            return false
        end
    end
    return true
end

function M.get_formula_index()
    local paths = M.paths()
    local cache_path = M.join(paths.cache_meta, "formula-index.json")
    local fh = io.open(cache_path, "r")
    if fh then
        local content = fh:read("*a")
        fh:close()
        local ok, cached = pcall(json.decode, content or "")
        if ok and type(cached) == "table" and type(cached.updated_at) == "number" then
            local age = os.time() - cached.updated_at
            if age >= 0 and age < M.FORMULA_INDEX_TTL and valid_formula_index(cached.formulae) then
                return cached.formulae
            end
        end
    end

    log.info("truebrew: downloading formulae index (~30MB; cached for 24 hours)")
    local data = M.get_json(M.API_BASE .. "/formula.json")
    if not valid_formula_index(data) then
        error("truebrew: invalid formulae index from " .. M.API_BASE)
    end
    local index = {}
    for _, formula in ipairs(data) do
        table.insert(index, { name = formula.name, desc = tostring(formula.desc or "") })
    end
    local encoded = json.encode({ updated_at = os.time(), formulae = index })
    -- Unique temporary files keep concurrent writers from interfering; rename
    -- publishes only a complete index. Cache failures must not break search.
    local tmp = M.trim(
        cmd.exec(
            "mkdir -p "
                .. M.shquote(paths.cache_meta)
                .. " && mktemp "
                .. M.shquote(cache_path .. ".XXXXXX")
                .. " || true"
        )
    )
    local saved = false
    if tmp ~= "" then
        local out = io.open(tmp, "w")
        if out then
            local written = out:write(encoded)
            local closed = out:close()
            if written and closed then
                saved = os.rename(tmp, cache_path)
            end
        end
        if not saved then
            os.remove(tmp)
        end
    end
    if not saved then
        log.warn("truebrew: could not cache formulae index at " .. cache_path)
    end
    return index
end

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

-- Memoize platform detection: one hook invocation == one platform, so the
-- sw_vers/uname subprocesses run once instead of once per formula.
do
    local _os_fn, _arch_fn, _mac_fn = M.current_os, M.current_arch, M.macos_major
    local _os, _arch, _macmajor, _mac_set = nil, nil, nil, false
    function M.current_os()
        if _os == nil then
            _os = _os_fn()
        end
        return _os
    end
    function M.current_arch()
        if _arch == nil then
            _arch = _arch_fn()
        end
        return _arch
    end
    function M.macos_major()
        if not _mac_set then
            _macmajor = _mac_fn()
            _mac_set = true
        end
        return _macmajor
    end
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

-- Pour relocation lives in lib/relocate.sh (single shell invocation).

-- Pour relocation runs as ONE shell invocation (lib/relocate.sh): per-call
-- bridge overhead dominates here, so the whole scan/rewrite/sign pass pays
-- it once no matter how many files a keg has.
function M.relocate_keg(keg_dir, prefix, cellar)
    if RUNTIME == nil or RUNTIME.pluginDirPath == nil then
        error("truebrew: RUNTIME.pluginDirPath unavailable (need plugin dir for relocate.sh)")
    end
    local script = M.join(RUNTIME.pluginDirPath, "lib", "relocate.sh")
    local ok, out = pcall(
        cmd.exec,
        "sh "
            .. M.shquote(script)
            .. " "
            .. M.shquote(keg_dir)
            .. " "
            .. M.shquote(prefix)
            .. " "
            .. M.shquote(cellar)
    )
    if not ok then
        error("truebrew: relocation failed for " .. keg_dir .. ": " .. tostring(out))
    end
    local macho, text, skipped = tostring(out or ""):match("TRUEBREW_RELOCATE macho=(%d+) text=(%d+) skipped=(%d+)")
    local extra = ""
    if (tonumber(skipped or "0") or 0) > 0 then
        extra = ", " .. skipped .. " skipped"
    end
    log.info(
        "truebrew: relocated "
            .. keg_dir
            .. " ("
            .. tostring(macho or "?")
            .. " Mach-O, "
            .. tostring(text or "?")
            .. " text"
            .. extra
            .. ")"
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
-- ---------------------------------------------------------------------------
-- parallel fetch (bottle downloads are latency-bound while a Lua hook is
-- single-threaded, so fan out through POSIX background jobs + `wait`)
-- ---------------------------------------------------------------------------

local _have_curl = nil

function M.have_curl()
    if _have_curl == nil then
        local ok, _ = pcall(cmd.exec, "command -v curl >/dev/null 2>&1")
        _have_curl = ok
    end
    return _have_curl
end

function M.parallel_jobs()
    local n = tonumber(os.getenv("TRUEBREW_JOBS") or os.getenv("MISE_JOBS") or "") or 8
    if n < 1 then
        n = 1
    elseif n > 16 then
        n = 16
    end
    return n
end

-- Run shell commands in background batches. Each command must be self-contained
-- and failure-safe (it records its own failures to a marker file); this raises
-- only when the batch scaffolding itself breaks.
function M.run_parallel(commands, max_jobs)
    if #commands == 0 then
        return
    end
    if #commands == 1 then
        max_jobs = 1
    else
        max_jobs = math.min(max_jobs or M.parallel_jobs(), #commands)
    end
    local batch = {}
    local function flush()
        if #batch == 0 then
            return
        end
        local script = table.concat(batch, " &\n") .. " &\nwait || true\n"
        local ok, err = pcall(cmd.exec, script)
        if not ok then
            error("truebrew: parallel step failed: " .. tostring(err))
        end
        batch = {}
    end
    for _, c in ipairs(commands) do
        table.insert(batch, "( " .. c .. " )")
        if #batch >= max_jobs then
            flush()
        end
    end
    flush()
end

-- Bump when relocation semantics change; older kegs are re-poured automatically.
M.RELOCATE_VERSION = 3

M._prefetch_seq = 0

-- Ensure formula JSONs for `names` are in the in-memory cache, fetching any
-- missing ones concurrently via curl (serial Lua fallback otherwise).
function M.ensure_formulas_cached(names, paths)
    local missing = {}
    for _, n in ipairs(names) do
        local key = M.normalize_tool(n)
        if not formula_cache[key] then
            table.insert(missing, key)
        end
    end
    if #missing == 0 then
        return
    end
    if M.have_curl() and #missing > 1 then
        M._prefetch_seq = M._prefetch_seq + 1
        local failfile = M.join(paths.cache_meta, "prefetch-" .. M._prefetch_seq .. ".FAIL")
        local dests = {}
        local cmds = {}
        for i, key in ipairs(missing) do
            local dest = M.join(paths.cache_meta, "prefetch-" .. M._prefetch_seq .. "-" .. i .. ".json")
            dests[key] = dest
            table.insert(
                cmds,
                "curl -fsSL --retry 2 --retry-delay 1 "
                    .. "-H "
                    .. M.shquote("User-Agent: mise-truebrew/0.1.0")
                    .. " -H "
                    .. M.shquote("Accept: application/json")
                    .. " -o "
                    .. M.shquote(dest)
                    .. " "
                    .. M.shquote(M.API_BASE .. "/formula/" .. key .. ".json")
                    .. " || echo "
                    .. M.shquote(key)
                    .. " >> "
                    .. M.shquote(failfile)
            )
        end
        pcall(cmd.exec, "rm -f " .. M.shquote(failfile))
        M.run_parallel(cmds, M.parallel_jobs())
        for _, key in ipairs(missing) do
            local dest = dests[key]
            if file.exists(dest) then
                local ok, content = pcall(file.read, dest)
                pcall(cmd.exec, "rm -f " .. M.shquote(dest))
                if ok and content then
                    local ok2, data = pcall(json.decode, content)
                    if
                        ok2
                        and type(data) == "table"
                        and type(data["versions"]) == "table"
                        and data["versions"]["stable"]
                        and not data["disabled"]
                    then
                        formula_cache[key] = data
                    end
                end
            end
            if not formula_cache[key] then
                -- Serial fallback: precise error (e.g. unknown formula) or success.
                M.get_formula(key)
            end
        end
        pcall(cmd.exec, "rm -f " .. M.shquote(failfile))
    else
        for _, key in ipairs(missing) do
            M.get_formula(key)
        end
    end
end

-- Resolve the full runtime closure, deps-first. Metadata is warmed level by
-- level (parallel fetches); ordering is a cache-hot DFS post-order.
function M.resolve_closure(root_name, paths)
    local os_name = M.current_os()
    local root_key = M.normalize_tool(root_name)
    local seen = { [root_key] = true }
    local levels = { { root_key } }
    local i = 1
    while i <= #levels do
        M.ensure_formulas_cached(levels[i], paths)
        local next_level = {}
        for _, key in ipairs(levels[i]) do
            for _, d in ipairs(M.runtime_deps(formula_cache[key], os_name)) do
                local dk = M.normalize_tool(d)
                if not seen[dk] then
                    seen[dk] = true
                    table.insert(next_level, dk)
                end
            end
        end
        if #next_level > 0 then
            table.insert(levels, next_level)
        end
        i = i + 1
    end
    local order, state = {}, {}
    local function visit(key)
        if state[key] == "done" then
            return
        end
        if state[key] == "visiting" then
            error("truebrew: dependency cycle detected at '" .. key .. "'")
        end
        state[key] = "visiting"
        local f = formula_cache[key]
        for _, d in ipairs(M.runtime_deps(f, os_name)) do
            visit(M.normalize_tool(d))
        end
        state[key] = "done"
        table.insert(order, { key = key, name = f["name"] or key, formula = f })
    end
    visit(root_key)
    return order
end

-- Ensure bottle blobs for closure items exist on disk. The bulk transfer runs
-- in parallel; sha256 verification stays serial (fast, local,
-- security-critical). Falls back to serial Lua downloads without curl.
function M.ensure_blobs(items, paths)
    if #items == 0 then
        return
    end
    M.ensure_dirs(paths)
    local missing = {}
    for _, item in ipairs(items) do
        local blob = M.join(paths.cache_blobs, item.sha .. ".tar.gz")
        item.blob = blob
        if file.exists(blob) then
            if M.sha256_of(blob) == item.sha then
                log.info("truebrew: cached bottle " .. blob)
            else
                log.warn("truebrew: cached blob checksum mismatch, re-downloading " .. blob)
                pcall(cmd.exec, "rm -f " .. M.shquote(blob))
                table.insert(missing, item)
            end
        else
            table.insert(missing, item)
        end
    end
    if #missing == 0 then
        return
    end
    if not M.have_curl() then
        for _, item in ipairs(missing) do
            M.download_bottle(item.entry["url"], item.sha, item.blob)
        end
        return
    end
    -- Tokens are tiny serial fetches; the bulk transfer below is parallel.
    for _, item in ipairs(missing) do
        item.token = M.ghcr_token(M.ghcr_repo_from_url(item.entry["url"]))
    end
    local failfile = M.join(paths.cache_blobs, "fetch.FAIL")
    pcall(cmd.exec, "rm -f " .. M.shquote(failfile))
    local cmds = {}
    for _, item in ipairs(missing) do
        table.insert(
            cmds,
            "curl -fsSL --retry 2 --retry-delay 1 "
                .. "-H "
                .. M.shquote("User-Agent: mise-truebrew/0.1.0")
                .. " -H "
                .. M.shquote("Accept: application/octet-stream")
                .. " -H "
                .. M.shquote("Authorization: Bearer " .. item.token)
                .. " -o "
                .. M.shquote(item.blob .. ".tmp")
                .. " "
                .. M.shquote(item.entry["url"])
                .. " && mv "
                .. M.shquote(item.blob .. ".tmp")
                .. " "
                .. M.shquote(item.blob)
                .. " || echo "
                .. M.shquote(item.name)
                .. " >> "
                .. M.shquote(failfile)
        )
    end
    log.info(
        "truebrew: downloading "
            .. #missing
            .. " bottles in parallel (x"
            .. math.min(M.parallel_jobs(), #missing)
            .. ")"
    )
    M.run_parallel(cmds, M.parallel_jobs())
    local ok, content = pcall(file.read, failfile)
    pcall(cmd.exec, "rm -f " .. M.shquote(failfile))
    if ok and content and M.trim(content) ~= "" then
        local failed = M.trim(content):gsub("\n", ", ")
        error("truebrew: failed to download bottles for: " .. failed)
    end
    for _, item in ipairs(missing) do
        if not file.exists(item.blob) then
            error("truebrew: bottle download missing for '" .. item.name .. "' (no error recorded)")
        end
        if M.sha256_of(item.blob) ~= item.sha then
            pcall(cmd.exec, "rm -f " .. M.shquote(item.blob))
            error("truebrew: sha256 mismatch for '" .. item.name .. "' bottle. Refusing to install.")
        end
    end
end

-- Pour one closure keg from its verified blob. Serial: extraction and
-- relocation are correctness-critical local work.
function M.pour_keg(item, paths)
    local name = item.name
    if file.exists(item.keg_dir) then
        M.refresh_opt_link(paths, name, item.keg_ver)
        return
    end
    log.info("truebrew: pouring " .. name .. " " .. item.keg_ver .. " (" .. item.tag .. ")")
    local ok, err = pcall(cmd.exec, "tar -xzf " .. M.shquote(item.blob) .. " -C " .. M.shquote(paths.cellar))
    if not ok then
        error("truebrew: extraction failed for " .. name .. ": " .. tostring(err))
    end
    if not file.exists(item.keg_dir) then
        error("truebrew: bottle for " .. name .. " did not contain expected keg " .. name .. "/" .. item.keg_ver)
    end
    M.relocate_keg(item.keg_dir, paths.prefix, paths.cellar)
    M.write_keg_receipt(item.keg_dir, {
        name = name,
        keg_version = item.keg_ver,
        stable = M.stable_version(item.formula),
        bottle_tag = item.tag,
        bottle_url = item.entry["url"],
        sha256 = item.sha,
        relocate_version = M.RELOCATE_VERSION,
        prefix = paths.prefix,
        cellar = paths.cellar,
        ruby_source_path = item.formula["ruby_source_path"],
        tap_git_head = item.formula["tap_git_head"],
        runtime_dependencies = M.runtime_deps(item.formula, M.current_os()),
    })
    M.refresh_opt_link(paths, name, item.keg_ver)
end

-- Install a formula + its runtime closure, deps-first. Network phases
-- (metadata, bottle downloads) run in parallel; pours stay serial.
-- Returns main keg_dir.
function M.install_with_deps(name, paths, stack)
    local t0 = os.time()
    M.ensure_dirs(paths)
    local order = M.resolve_closure(name, paths)
    local need = {}
    for _, item in ipairs(order) do
        local tag, entry = M.select_bottle(item.formula)
        item.tag = tag
        item.entry = entry
        item.keg_ver = M.keg_version(item.formula)
        item.keg_dir = M.keg_dir(paths, item.name, item.keg_ver)
        item.sha = tostring(entry["sha256"]):lower()
        local receipt = M.read_keg_receipt(item.keg_dir)
        if
            receipt
            and receipt["sha256"] == item.sha
            and receipt["relocate_version"] == M.RELOCATE_VERSION
            and file.exists(item.keg_dir)
        then
            log.info("truebrew: already installed " .. item.name .. " " .. item.keg_ver)
            M.refresh_opt_link(paths, item.name, item.keg_ver)
            item.done = true
        else
            if receipt and receipt["sha256"] == item.sha and file.exists(item.keg_dir) then
                -- Same bottle, outdated relocation (e.g. fixed placeholder
                -- handling): re-pour from the cached blob.
                log.info("truebrew: re-pouring " .. item.name .. " with current relocation")
                pcall(cmd.exec, "rm -rf " .. M.shquote(item.keg_dir))
            elseif file.exists(item.keg_dir) and receipt == nil then
                -- Foreign/partial dir: only reuse when it looks complete.
                if not file.exists(M.join(item.keg_dir, "INSTALL_RECEIPT.json")) then
                    log.warn("truebrew: removing incomplete keg dir " .. item.keg_dir)
                    pcall(cmd.exec, "rm -rf " .. M.shquote(item.keg_dir))
                end
            end
            table.insert(need, item)
        end
    end
    log.info(
        "truebrew: closure for '"
            .. name
            .. "': "
            .. #order
            .. " kegs ("
            .. #need
            .. " to pour, "
            .. (os.time() - t0)
            .. "s resolve)"
    )
    local t1 = os.time()
    M.ensure_blobs(need, paths)
    log.info("truebrew: bottles ready (" .. (os.time() - t1) .. "s fetch+verify)")
    local t2 = os.time()
    for _, item in ipairs(need) do
        M.pour_keg(item, paths)
    end
    log.info("truebrew: poured " .. #need .. " kegs (" .. (os.time() - t2) .. "s pour)")
    for _, item in ipairs(order) do
        M.ensure_post_install(item, paths)
    end
    return order[#order].keg_dir
end

-- ---------------------------------------------------------------------------
-- dependency queries
-- ---------------------------------------------------------------------------

-- Use installed receipts to cover direct and transitive dependencies,
-- including relinks of older kegs, without fetching current formula metadata.
function M.uses_dep(keg_dir, prefix, matches, seen)
    seen = seen or {}
    if seen[keg_dir] then
        return false
    end
    seen[keg_dir] = true
    local receipt = M.read_keg_receipt(keg_dir)
    if not receipt then
        return false
    end
    if matches(receipt.name) then
        return true
    end
    for _, dep in ipairs(receipt.runtime_dependencies or {}) do
        if matches(dep) or M.uses_dep(M.join(prefix, "opt", dep), prefix, matches, seen) then
            return true
        end
    end
    return false
end

function M.is_openssl(name)
    return name == "openssl" or tostring(name):match("^openssl@") ~= nil
end

function M.uses_ncurses(keg_dir, prefix)
    return M.uses_dep(keg_dir, prefix, function(name)
        return name == "ncurses"
    end)
end

function M.uses_openssl(keg_dir, prefix)
    return M.uses_dep(keg_dir, prefix, M.is_openssl)
end

-- ---------------------------------------------------------------------------
-- post_install_steps (Homebrew's declarative post-install, served by the API)
-- ---------------------------------------------------------------------------
-- Bottles never ship etc/ or var/; formulae populate them (and fix up their
-- kegs) in post_install. Homebrew serialises that as data, so this mirrors
-- Homebrew::InstallSteps::Runner. Actions that wrap Ruby logic, need sudo,
-- or start services are skipped with a warning.

-- Bump when step semantics change; kegs re-run their steps on next install.
M.POST_INSTALL_VERSION = 1

function M.ca_bundle(prefix)
    return M.join(prefix, "etc", "ca-certificates", "cert.pem")
end

local Q = M.shquote

local function sh_ok(script)
    return (pcall(cmd.exec, script))
end

local function exists(p)
    return sh_ok("test -e " .. Q(p))
end

local function is_link(p)
    return sh_ok("test -L " .. Q(p))
end

local function is_dir(p)
    return sh_ok("test -d " .. Q(p))
end

local function dirname(p)
    return p:gsub("/+$", ""):match("^(.*)/[^/]*$") or "."
end

local function basename(p)
    return (p:gsub("/+$", ""):match("([^/]*)$"))
end

local function mkdir_p(p)
    cmd.exec("mkdir -p " .. Q(p))
end

-- Tokens usable inside templated strings (Runner::CONTENT_PATH_TOKENS).
local CONTENT_PATH_TOKENS = {
    prefix = true,
    opt_prefix = true,
    bin = true,
    sbin = true,
    lib = true,
    libexec = true,
    share = true,
    pkgshare = true,
    var = true,
    etc = true,
    pkgetc = true,
    temp = true,
    rack = true,
    bash_completion = true,
    zsh_completion = true,
    fish_completion = true,
    pwsh_completion = true,
}

function M.post_install_context(item, paths)
    local keg = item.keg_dir
    local name = item.name
    local version = M.stable_version(item.formula)
    local major, minor = version:match("^(%d+)%.?(%d*)")
    local share = M.join(keg, "share")
    local etc = M.join(paths.prefix, "etc")
    return {
        name = name,
        version = version,
        version_major = major,
        version_major_minor = (major and minor ~= "") and (major .. "." .. minor) or major,
        paths = paths,
        guards = {},
        roots = {
            prefix = keg,
            opt_prefix = M.join(paths.opt, name),
            bin = M.join(keg, "bin"),
            sbin = M.join(keg, "sbin"),
            lib = M.join(keg, "lib"),
            libexec = M.join(keg, "libexec"),
            include = M.join(keg, "include"),
            frameworks = M.join(keg, "Frameworks"),
            share = share,
            pkgshare = M.join(share, name),
            man = M.join(share, "man"),
            doc = M.join(share, "doc", name),
            etc = etc,
            pkgetc = M.join(etc, name),
            var = M.join(paths.prefix, "var"),
            rack = M.join(paths.cellar, name),
            homebrew_prefix = paths.prefix,
            temp = os.getenv("TMPDIR") or "/tmp",
            home = M.home(),
            bash_completion = M.join(keg, "etc", "bash_completion.d"),
            zsh_completion = M.join(share, "zsh", "site-functions"),
            fish_completion = M.join(share, "fish", "vendor_completions.d"),
            pwsh_completion = M.join(share, "pwsh", "completions"),
        },
    }
end

-- Unknown tokens stay verbatim, as in Homebrew.
function M.expand_tokens(ctx, s)
    return (tostring(s):gsub("{{([%a_][%w_.]*)}}", function(tok)
        if tok == "HOMEBREW_PREFIX" then
            return ctx.paths.prefix
        elseif tok == "HOMEBREW_CELLAR" then
            return ctx.paths.cellar
        elseif tok == "formula_name" or tok == "name" then
            return ctx.name
        elseif tok == "user" then
            return os.getenv("USER")
        elseif tok == "version" then
            return ctx.version
        elseif tok == "version.major" then
            return ctx.version_major
        elseif tok == "version.major_minor" then
            return ctx.version_major_minor
        elseif CONTENT_PATH_TOKENS[tok] then
            return ctx.roots[tok]
        end
        return nil
    end))
end

function M.step_path(ctx, spec)
    local path = M.expand_tokens(ctx, spec["path"])
    local base = spec["base"]
    if base == nil or base == "" or base == "absolute" or base == "relative" then
        return path
    end
    local root
    if base == "formula_pkgetc" or base == "formula_opt_prefix" then
        local formula = tostring(spec["formula"] or ""):match("([^/]+)$")
        if not formula or formula == "" then
            error("missing formula for install step base " .. base)
        end
        root = base == "formula_pkgetc" and M.join(ctx.paths.prefix, "etc", formula) or M.join(ctx.paths.opt, formula)
    else
        root = ctx.roots[base]
    end
    if not root then
        error("unknown install step base: " .. tostring(base))
    end
    return root .. "/" .. path
end

-- Ruby Pathname.glob semantics via bash: braces, `**`, no dotfiles.
function M.step_glob(ctx, spec)
    local path = M.step_path(ctx, spec)
    if not path:find("[%*%?%[{]") then
        return { path }
    end
    local escaped = path:gsub("([^%w%*%?%[%]{},/._%-])", "\\%1")
    local script = 'shopt -s globstar nullglob; eval "set -- $1"; '
        .. 'for p; do if [ -e "$p" ] || [ -L "$p" ]; then printf "%s\\n" "$p"; fi; done'
    local out = cmd.exec("bash -c " .. Q(script) .. " _ " .. Q(escaped))
    local list = {}
    for line in tostring(out or ""):gmatch("[^\n]+") do
        table.insert(list, line)
    end
    return list
end

local function spec_exists(ctx, spec)
    for _, p in ipairs(M.step_glob(ctx, spec)) do
        if exists(p) then
            return true
        end
    end
    return false
end

-- Guard results are snapshotted once per run, as in Homebrew.
function M.step_guards_match(ctx, step)
    for _, guard in ipairs(step["guards"] or {}) do
        local key = guard["id"] or json.encode(guard)
        local result = ctx.guards[key]
        if result == nil then
            local cond = guard["condition"]
            if cond == "if_exists" then
                result = spec_exists(ctx, guard)
            elseif cond == "unless_exists" then
                result = not spec_exists(ctx, guard)
            elseif cond == "on" then
                local os_name = M.current_os() == "linux" and "linux" or "macos"
                result = guard["value"] == os_name
            else
                result = false
            end
            ctx.guards[key] = result
        end
        if not result then
            return false
        end
    end
    return true
end

local function step_source(ctx, step)
    if step["source_glob"] ~= true then
        return M.step_path(ctx, step["source"])
    end
    local sources = M.step_glob(ctx, step["source"])
    if #sources ~= 1 then
        error("install step source glob must match exactly one path: " .. M.step_path(ctx, step["source"]))
    end
    return sources[1]
end

local function step_destination(source, target)
    return is_dir(target) and (target .. "/" .. basename(source)) or target
end

local function step_paths(ctx, step)
    local list = {}
    for _, spec in ipairs(step["paths"] or {}) do
        for _, p in ipairs(M.step_glob(ctx, spec)) do
            table.insert(list, p)
        end
    end
    return list
end

local function create_symlink(source, target, step)
    if step["sudo"] == true then
        error("requires sudo")
    end
    mkdir_p(dirname(target))
    if step["force"] == true then
        pcall(cmd.exec, "rm -f " .. Q(target))
    end
    if exists(target) or is_link(target) then
        error("file exists: " .. target)
    end
    cmd.exec("ln -s " .. Q(source) .. " " .. Q(target))
end

local function write_atomic(path, content)
    mkdir_p(dirname(path))
    local tmp = path .. ".truebrew-tmp"
    local fh, err = io.open(tmp, "w")
    if not fh then
        error("cannot write " .. path .. ": " .. tostring(err))
    end
    fh:write(content)
    fh:close()
    cmd.exec("mv -f " .. Q(tmp) .. " " .. Q(path))
end

local function run_formula_tool(ctx, formula, executable, args)
    local tool = M.join(ctx.paths.opt, formula, "bin", executable)
    if not sh_ok("test -x " .. Q(tool)) then
        error(formula .. " is missing required executable: " .. tool)
    end
    local line = Q(tool)
    for _, a in ipairs(args) do
        line = line .. " " .. Q(a)
    end
    cmd.exec(line)
end

-- Same fallback as relocate.sh for an unusable xcrun-backed otool shim.
local function macho_tool_env()
    if sh_ok("otool -h /bin/ls >/dev/null 2>&1") then
        return ""
    end
    return "DEVELOPER_DIR=/Library/Developer/CommandLineTools "
end

M.POST_INSTALL_STEPS = {
    mkdir = function(ctx, step)
        cmd.exec("mkdir " .. Q(M.step_path(ctx, step["path"])))
    end,
    mkdir_p = function(ctx, step)
        mkdir_p(M.step_path(ctx, step["path"]))
    end,
    touch = function(ctx, step)
        local p = M.step_path(ctx, step["path"])
        mkdir_p(dirname(p))
        cmd.exec("touch " .. Q(p))
    end,
    move = function(ctx, step)
        local source = step_source(ctx, step)
        local target = M.step_path(ctx, step["target"])
        mkdir_p(dirname(target))
        if step["overwrite"] ~= nil then
            local destination = step_destination(source, target)
            local overwrite = step["overwrite"] == true or step["force"] == true
            if exists(destination) and not overwrite then
                error("file exists: " .. destination)
            end
            if overwrite and destination ~= source and (exists(source) or is_link(source)) then
                cmd.exec("rm -rf " .. Q(destination))
            end
            cmd.exec("mv " .. Q(source) .. " " .. Q(target))
        else
            cmd.exec("mv " .. (step["force"] == true and "-f " or "") .. Q(source) .. " " .. Q(target))
        end
    end,
    move_children = function(ctx, step)
        local script = 'mkdir -p "$2" && for c in "$1"/* "$1"/.[!.]* "$1"/..?*; do '
            .. '{ [ -e "$c" ] || [ -L "$c" ]; } && [ "$c" != "$2" ] && mv "$c" "$2"/; done; true'
        cmd.exec(
            "sh -c "
                .. Q(script)
                .. " _ "
                .. Q(M.step_path(ctx, step["source"]))
                .. " "
                .. Q(M.step_path(ctx, step["target"]))
        )
    end,
    copy = function(ctx, step)
        local source = step_source(ctx, step)
        local target = M.step_path(ctx, step["target"])
        mkdir_p(dirname(target))
        local destination = step_destination(source, target)
        local overwrite = step["overwrite"] ~= false
        if exists(destination) and not overwrite then
            error("file exists: " .. destination)
        end
        if step["recursive"] == true then
            cmd.exec("cp -R " .. Q(source) .. " " .. Q(target))
        else
            if overwrite and is_link(destination) then
                cmd.exec("rm -f " .. Q(destination))
            end
            cmd.exec("cp " .. Q(source) .. " " .. Q(target))
        end
    end,
    remove = function(ctx, step)
        if step["sudo"] == true then
            error("requires sudo")
        end
        for _, p in ipairs(step_paths(ctx, step)) do
            local keep = true
            local needle = step["symlink_target_contains"]
            if needle then
                local ok, dest = pcall(cmd.exec, "readlink " .. Q(p))
                keep = ok and tostring(dest):find(needle, 1, true) ~= nil
            end
            needle = step["content_contains"]
            if keep and needle then
                local ok, content = pcall(file.read, p)
                keep = ok and content ~= nil and content:find(needle, 1, true) ~= nil
            end
            if keep then
                cmd.exec((step["recursive"] == true and "rm -rf " or "rm -f ") .. Q(p))
            end
        end
    end,
    inreplace = function(ctx, step)
        local pattern = step["regexp"] == true and "$tb_before" or "\\Q$tb_before\\E"
        local flags = step["first_only"] == true and "" or "g"
        local audit = step["skip_audit"] ~= true and "$tb_n ? 0 : 1" or "0"
        local script = "BEGIN { $tb_before = $ENV{TB_BEFORE}; $tb_after = $ENV{TB_AFTER}; $tb_n = 0 } "
            .. ("$tb_n++ if s/" .. pattern .. "/$tb_after/" .. flags .. "; ")
            .. ("END { exit(" .. audit .. ") }")
        local ok, err = pcall(
            cmd.exec,
            "TB_BEFORE="
                .. Q(M.expand_tokens(ctx, step["before"]))
                .. " TB_AFTER="
                .. Q(M.expand_tokens(ctx, step["after"]))
                .. " perl -0777 -pi -e "
                .. Q(script)
                .. " "
                .. Q(M.step_path(ctx, step["path"]))
        )
        if not ok then
            error("inreplace failed (no match?): " .. tostring(err))
        end
    end,
    link_dir = function(ctx, step)
        local script = [[
src=$1 tgt=$2
cd "$src" || exit 1
find . | while IFS= read -r rel; do
    s="$src/$rel" t="$tgt/$rel"
    [ "$(basename "$rel")" = .DS_Store ] && continue
    [ -d "$t" ] && [ ! -L "$t" ] && continue
    if [ -e "$t" ] || [ -L "$t" ]; then rm -f "$t"; fi
    if [ -L "$s" ] || [ -f "$s" ]; then
        mkdir -p "$(dirname "$t")" && ln -s "$s" "$t" || exit 1
    elif [ -d "$s" ]; then
        mkdir -p "$t" || exit 1
    fi
done]]
        cmd.exec(
            "sh -c "
                .. Q(script)
                .. " _ "
                .. Q(M.step_path(ctx, step["source"]))
                .. " "
                .. Q(M.step_path(ctx, step["target"]))
        )
    end,
    link_children = function(ctx, step)
        local script = 'mkdir -p "$2" && for c in "$1"/* "$1"/.[!.]* "$1"/..?*; do '
            .. '{ [ -e "$c" ] || [ -L "$c" ]; } || continue; '
            .. 'ln -sfn "$c" "$2/$3$(basename "$c")$4" || exit 1; done'
        cmd.exec(
            "sh -c "
                .. Q(script)
                .. " _ "
                .. Q(M.step_path(ctx, step["source"]))
                .. " "
                .. Q(M.step_path(ctx, step["target"]))
                .. " "
                .. Q(M.expand_tokens(ctx, step["prefix"] or ""))
                .. " "
                .. Q(M.expand_tokens(ctx, step["suffix"] or ""))
        )
    end,
    symlink = function(ctx, step)
        local target = M.step_path(ctx, step["target"])
        if step["source_glob"] ~= true then
            create_symlink(M.step_path(ctx, step["source"]), target, step)
            return
        end
        local sources = M.step_glob(ctx, step["source"])
        if #sources == 0 then
            return
        end
        if #sources > 1 or is_dir(target) then
            mkdir_p(target)
            for _, source in ipairs(sources) do
                create_symlink(source, target .. "/" .. basename(source), step)
            end
        else
            create_symlink(sources[1], target, step)
        end
    end,
    write = function(ctx, step)
        if step["content"] == nil then
            error("install step write requires content")
        end
        local p = M.step_path(ctx, step["path"])
        if step["overwrite"] == true or not exists(p) then
            write_atomic(p, M.expand_tokens(ctx, step["content"]))
        end
    end,
    run = function(ctx, step)
        if step["sudo"] == true then
            error("requires sudo")
        end
        local spec = step["command"]
        local line = "env"
        for k, v in pairs(step["env"] or {}) do
            line = line .. " " .. Q(k .. "=" .. M.expand_tokens(ctx, v))
        end
        line = line .. " " .. Q(M.step_path(ctx, spec))
        for _, a in ipairs(step["args"] or {}) do
            line = line .. " " .. Q(M.expand_tokens(ctx, a))
        end
        if step["chdir"] then
            line = "cd " .. Q(M.step_path(ctx, step["chdir"])) .. " && " .. line
        end
        if step["stdin_path"] then
            line = line .. " <" .. Q(M.step_path(ctx, step["stdin_path"]))
        end
        local out_path = step["stdout_path"] and M.step_path(ctx, step["stdout_path"])
        local ok, out = pcall(cmd.exec, line)
        if not ok then
            if step["allow_failure"] == true then
                return
            end
            error(out)
        end
        if out_path then
            write_atomic(out_path, tostring(out or ""))
        end
    end,
    warn = function(ctx, step)
        log.warn("truebrew: " .. ctx.name .. ": " .. M.expand_tokens(ctx, step["message"]))
    end,
    set_permissions = function(ctx, step)
        local line = "chmod" .. (step["non_recursive"] == true and "" or " -R") .. " -- " .. Q(step["permissions"])
        local any = false
        for _, p in ipairs(step_paths(ctx, step)) do
            if exists(p) then
                line = line .. " " .. Q(p)
                any = true
            end
        end
        if any then
            cmd.exec(line)
        end
    end,
    install_gzipped_executable = function(ctx, step)
        local source = M.step_path(ctx, step["source"])
        if not exists(source) then
            return
        end
        local target = M.step_path(ctx, step["target"])
        local tmp = dirname(target) .. "/." .. basename(target) .. ".install-step"
        mkdir_p(dirname(target))
        cmd.exec(
            ("gunzip -c " .. Q(source) .. " > " .. Q(tmp))
                .. (" && mv -f " .. Q(tmp) .. " " .. Q(target))
                .. (" && rm -f " .. Q(source) .. " && chmod 755 " .. Q(target))
        )
    end,
    change_dylib_id = function(ctx, step)
        local source = M.step_path(ctx, step["source"])
        if step["resolve_source"] == true then
            source = M.trim(cmd.exec("perl -MCwd -e 'print Cwd::realpath(shift)' " .. Q(source)))
        end
        local id = M.expand_tokens(ctx, step["id"])
        cmd.exec(macho_tool_env() .. "install_name_tool -id " .. Q(id) .. " " .. Q(source))
        cmd.exec("codesign -f -s - " .. Q(source))
    end,
    compile_gsettings_schemas = function(ctx, step)
        run_formula_tool(ctx, "glib", "glib-compile-schemas", { M.step_path(ctx, step["path"]) })
    end,
    gio_querymodules = function(ctx, step)
        run_formula_tool(ctx, "glib", "gio-querymodules", { M.step_path(ctx, step["path"]) })
    end,
    gdk_pixbuf_query_loaders = function(ctx, _)
        run_formula_tool(ctx, "gdk-pixbuf", "gdk-pixbuf-query-loaders", { "--update-cache" })
    end,
    gtk_update_icon_cache = function(ctx, step)
        local p = M.step_path(ctx, step["path"])
        if file.exists(M.join(ctx.paths.opt, "gtk4")) then
            run_formula_tool(ctx, "gtk4", "gtk4-update-icon-cache", { "-q", "-t", "-f", p })
        else
            run_formula_tool(ctx, "gtk+3", "gtk3-update-icon-cache", { "-q", "-t", "-f", p })
        end
    end,
    update_mime_database = function(ctx, step)
        run_formula_tool(ctx, "shared-mime-info", "update-mime-database", { M.step_path(ctx, step["path"]) })
    end,
    update_desktop_database = function(ctx, step)
        run_formula_tool(ctx, "desktop-file-utils", "update-desktop-database", { M.step_path(ctx, step["path"]) })
    end,
}
M.POST_INSTALL_STEPS.move_contents = M.POST_INSTALL_STEPS.move_children

-- Like `brew postinstall`: the first failing step aborts the rest with a
-- warning, but the keg stays installed. Returns true when the steps are done
-- (unsupported steps are skipped, not retried).
function M.run_post_install(item, paths)
    local steps = item.formula["post_install_steps"] or {}
    if #steps == 0 then
        return true
    end
    local ctx = M.post_install_context(item, paths)
    for i, step in ipairs(steps) do
        local kind = tostring(step["type"])
        if M.step_guards_match(ctx, step) then
            local fn = M.POST_INSTALL_STEPS[kind]
            if not fn then
                log.warn("truebrew: " .. item.name .. ": skipping unsupported post-install step '" .. kind .. "'")
            else
                local ok, err = pcall(fn, ctx, step)
                if not ok then
                    log.warn(
                        "truebrew: "
                            .. item.name
                            .. ": post-install step "
                            .. i
                            .. " ("
                            .. kind
                            .. ") failed, skipping the rest: "
                            .. tostring(err)
                    )
                    return false
                end
            end
        end
    end
    log.info("truebrew: ran " .. #steps .. " post-install steps for " .. item.name)
    return true
end

-- Runs once per poured keg; the receipt records completion.
function M.ensure_post_install(item, paths)
    local receipt = M.read_keg_receipt(item.keg_dir)
    if not receipt or receipt["post_install_version"] == M.POST_INSTALL_VERSION then
        return
    end
    if M.run_post_install(item, paths) then
        receipt["post_install_version"] = M.POST_INSTALL_VERSION
        local ok, encoded = pcall(json.encode, receipt)
        if ok then
            write_atomic(M.join(item.keg_dir, ".truebrew.json"), encoded)
        end
    end
end

-- ---------------------------------------------------------------------------
-- mise shim (install_path)
-- ---------------------------------------------------------------------------

-- opts.terminfo: relocated ncurses database to append to TERMINFO_DIRS.
-- opts.ca_bundle: default SSL_CERT_FILE. Bottled OpenSSL hardcodes
-- OPENSSLDIR=/opt/homebrew/etc/openssl@N, which does not exist here.
function M.write_launcher(dest, src, opts)
    local fh, err = io.open(dest, "w")
    if not fh then
        error("truebrew: cannot write launcher " .. dest .. ": " .. tostring(err))
    end
    fh:write("#!/bin/sh\n")
    if opts.terminfo then
        fh:write("# Restore the relocated database even when sudo drops the environment.\n")
        fh:write("truebrew_terminfo=" .. M.shquote(opts.terminfo) .. "\n")
        fh:write('if [ -d "$truebrew_terminfo" ]; then\n')
        fh:write('    case ":${TERMINFO_DIRS-}:" in\n')
        fh:write('        *":$truebrew_terminfo:"*) ;;\n')
        fh:write(
            '        *) TERMINFO_DIRS="${TERMINFO_DIRS:+$TERMINFO_DIRS:}$truebrew_terminfo:"; export TERMINFO_DIRS ;;\n'
        )
        fh:write("    esac\nfi\n")
    end
    if opts.ca_bundle then
        fh:write("# Bottled OpenSSL looks for certificates under /opt/homebrew.\n")
        fh:write("truebrew_ca_bundle=" .. M.shquote(opts.ca_bundle) .. "\n")
        fh:write('if [ -z "${SSL_CERT_FILE-}" ] && [ -f "$truebrew_ca_bundle" ]; then\n')
        fh:write('    SSL_CERT_FILE="$truebrew_ca_bundle"; export SSL_CERT_FILE\n')
        fh:write("fi\n")
    end
    fh:write("exec " .. M.shquote(src) .. ' "$@"\n')
    fh:close()
    cmd.exec("chmod 755 " .. M.shquote(dest))
end

function M.write_shim(install_path, keg_dir, meta)
    pcall(cmd.exec, "mkdir -p " .. M.shquote(M.join(install_path, "bin")))
    -- Ncurses and OpenSSL consumers need a launcher: sudo or a direct path
    -- invocation bypasses BackendExecEnv. Other executables keep symlinks.
    local launcher = {}
    if M.uses_ncurses(keg_dir, meta.prefix) then
        launcher.terminfo = M.join(meta.prefix, "opt", "ncurses", "share", "terminfo")
    end
    if M.uses_openssl(keg_dir, meta.prefix) then
        launcher.ca_bundle = M.ca_bundle(meta.prefix)
    end
    local needs_launcher = next(launcher) ~= nil
    for _, sub in ipairs({ "bin", "sbin" }) do
        local src_dir = M.join(keg_dir, sub)
        if file.exists(src_dir) then
            for _, base in ipairs(M.dir_entries(src_dir)) do
                local src = M.join(src_dir, base)
                local dest = M.join(install_path, "bin", base)
                if M.is_file_like(src) then
                    pcall(cmd.exec, "rm -f " .. M.shquote(dest))
                    if needs_launcher then
                        M.write_launcher(dest, src, launcher)
                    else
                        local ok2, err2 =
                            pcall(cmd.exec, "ln -s " .. M.shquote(src) .. " " .. M.shquote(dest))
                        if not ok2 then
                            error("truebrew: cannot link " .. base .. ": " .. tostring(err2))
                        end
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
