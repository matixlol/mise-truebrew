-- Exercise the post_install_steps runner against a scratch prefix.
-- Usage: lua tests/post_install_steps.lua  (Lua 5.1; stubs mise's modules)

local function sh(command)
    local fh = io.popen("(" .. command .. ") 2>&1; printf '\\n%s' $?")
    local out = fh:read("*a")
    fh:close()
    local body, status = out:match("^(.*)\n(%d+)$")
    if status ~= "0" then
        error("command failed (" .. status .. "): " .. command .. "\n" .. body, 2)
    end
    return body
end

local warnings = {}
package.preload["cmd"] = function()
    return { exec = sh }
end
package.preload["file"] = function()
    return {
        join_path = function(...)
            return (table.concat({ ... }, "/"):gsub("/+", "/"))
        end,
        exists = function(p)
            return (pcall(sh, "test -e '" .. p .. "'"))
        end,
        read = function(p)
            local fh = assert(io.open(p))
            local s = fh:read("*a")
            fh:close()
            return s
        end,
    }
end
package.preload["json"] = function()
    return {
        encode = function(v)
            return tostring(v)
        end,
    }
end
package.preload["log"] = function()
    return {
        info = function() end,
        warn = function(msg)
            table.insert(warnings, msg)
        end,
    }
end
package.preload["http"] = function()
    return {}
end

local plugin_dir = arg[0]:match("^(.*)/tests/[^/]*$") or "."
local M = dofile(plugin_dir .. "/lib/truebrew.lua")

local root = sh('mktemp -d "${TMPDIR:-/tmp}/truebrew-steps.XXXXXX"'):gsub("%s+$", "")
local paths = M.paths({ root = root })
local keg = M.join(paths.cellar, "demo", "1.2.3")
sh("mkdir -p '" .. keg .. "/libexec/tree/sub' '" .. keg .. "/bin' '" .. keg .. "/share/demo'")
sh("echo hi > '" .. keg .. "/libexec/tree/sub/a.txt' && echo man > '" .. keg .. "/share/demo/x-one.1'")
sh("echo man > '" .. keg .. "/share/demo/y-two.1' && echo skip > '" .. keg .. "/share/demo/z.1'")
sh("printf 'path=@OLD@ and @OLD@\\n' > '" .. keg .. "/libexec/conf'")
sh("printf '#!/bin/sh\\necho gz-ok\\n' | gzip > '" .. keg .. "/libexec/tool.gz'")
sh(
    "printf '#!/bin/sh\\necho \"$DEMO_ENV:$1:$(cat)\"\\n' > '"
        .. keg
        .. "/bin/emit' && chmod 755 '"
        .. keg
        .. "/bin/emit'"
)
sh("mkdir -p '" .. paths.opt .. "' && ln -s ../Cellar/demo/1.2.3 '" .. paths.opt .. "/demo'")
sh("printf 'stdin-data' > '" .. keg .. "/libexec/input'")

local function P(path, base)
    return { path = path, base = base }
end

local steps = {
    { type = "mkdir_p", path = P("{{var}}/demo/{{version.major_minor}}") },
    { type = "touch", path = P("demo/stamp", "var") },
    { type = "write", path = P("demo.conf", "pkgetc"), content = "prefix={{HOMEBREW_PREFIX}} v={{version}}\n" },
    -- overwrite=false (default) keeps the existing file.
    { type = "write", path = P("demo.conf", "pkgetc"), content = "clobbered\n" },
    { type = "copy", source = P("tree", "libexec"), target = P("{{HOMEBREW_PREFIX}}/lib/demo"), recursive = true },
    { type = "symlink", source = P("{{etc}}/demo/demo.conf"), target = P("{{pkgetc}}/link.conf"), force = true },
    {
        type = "symlink",
        source = P("{{pkgshare}}/{x,y}-*.1"),
        target = P("{{HOMEBREW_PREFIX}}/share/man/man1"),
        source_glob = true,
        force = true,
    },
    { type = "inreplace", path = P("conf", "libexec"), before = "@OLD@", after = "{{opt_prefix}}" },
    { type = "link_dir", source = P("tree", "libexec"), target = P("demo-tree", "homebrew_prefix") },
    {
        type = "link_children",
        source = P("bin", "prefix"),
        target = P("bin", "homebrew_prefix"),
        suffix = "-{{version.major}}",
    },
    { type = "install_gzipped_executable", source = P("tool.gz", "libexec"), target = P("tool", "libexec") },
    {
        type = "run",
        command = P("emit", "bin"),
        args = { "{{formula_name}}" },
        env = { DEMO_ENV = "{{version.major}}" },
        stdin_path = P("input", "libexec"),
        stdout_path = P("demo/run.out", "var"),
    },
    { type = "remove", paths = { P("{{pkgshare}}/z.*") } },
    { type = "set_permissions", paths = { P("demo/stamp", "var") }, permissions = "0600", non_recursive = true },
    -- Guards: skipped because the path exists / wrong OS / snapshot semantics.
    {
        type = "mkdir_p",
        path = P("demo/never", "var"),
        guards = { { id = "1", condition = "unless_exists", base = "var", path = "demo" } },
    },
    {
        type = "mkdir_p",
        path = P("demo/never2", "var"),
        guards = { { id = "2", condition = "on", value = "windows" } },
    },
    { type = "warn", message = "hello from {{formula_name}}" },
    { type = "configure_php" },
    { type = "move", source = P("demo/stamp", "var"), target = P("demo/moved", "var"), overwrite = true },
}

local item = {
    name = "demo",
    keg_dir = keg,
    formula = { name = "demo", versions = { stable = "1.2.3" }, post_install_steps = steps },
}
assert(M.run_post_install(item, paths), "steps should complete")

local function read(p)
    return sh("cat '" .. p .. "'")
end
local function check(cond, what)
    if not cond then
        error("FAIL: " .. what, 2)
    end
end
local pre = paths.prefix
check(read(pre .. "/etc/demo/demo.conf") == "prefix=" .. pre .. " v=1.2.3\n", "write + tokens")
check(pcall(sh, "test -d '" .. pre .. "/var/demo/1.2'"), "mkdir_p major_minor")
check(read(pre .. "/lib/demo/sub/a.txt") == "hi\n", "recursive copy")
check(sh("readlink '" .. pre .. "/etc/demo/link.conf'") == pre .. "/etc/demo/demo.conf\n", "symlink")
check(
    pcall(sh, "test -L '" .. pre .. "/share/man/man1/x-one.1' && test -L '" .. pre .. "/share/man/man1/y-two.1'"),
    "brace glob symlink"
)
check(not pcall(sh, "test -e '" .. pre .. "/share/man/man1/z.1'"), "glob excludes")
check(read(keg .. "/libexec/conf") == "path=" .. pre .. "/opt/demo and " .. pre .. "/opt/demo\n", "inreplace global")
check(
    read(pre .. "/demo-tree/sub/a.txt") == "hi\n" and pcall(sh, "test -L '" .. pre .. "/demo-tree/sub/a.txt'"),
    "link_dir"
)
check(pcall(sh, "test -L '" .. pre .. "/bin/emit-1'"), "link_children suffix")
check(
    sh("'" .. keg .. "/libexec/tool'") == "gz-ok\n" and not pcall(sh, "test -e '" .. keg .. "/libexec/tool.gz'"),
    "gzipped executable"
)
check(read(pre .. "/var/demo/run.out") == "1:demo:stdin-data\n", "run env/args/stdin/stdout")
check(not pcall(sh, "test -e '" .. keg .. "/share/demo/z.1'"), "remove glob")
check(sh("ls -l '" .. pre .. "/var/demo/moved'"):match("^%-rw%-%-%-%-%-%-%-"), "set_permissions then move")
check(not pcall(sh, "test -e '" .. pre .. "/var/demo/never'"), "unless_exists guard")
check(not pcall(sh, "test -e '" .. pre .. "/var/demo/never2'"), "on guard")
local joined = table.concat(warnings, "\n")
check(joined:find("hello from demo", 1, true), "warn step")
check(joined:find("unsupported post-install step 'configure_php'", 1, true), "unsupported step warns")

-- A failing step stops the run and reports failure.
item.formula.post_install_steps = {
    { type = "inreplace", path = P("conf", "libexec"), before = "@MISSING@", after = "x" },
    { type = "mkdir_p", path = P("demo/after-failure", "var") },
}
check(not M.run_post_install(item, paths), "failed audit reports failure")
check(not pcall(sh, "test -e '" .. pre .. "/var/demo/after-failure'"), "failure stops later steps")

sh("rm -rf '" .. root .. "'")
print("post_install_steps: OK")
