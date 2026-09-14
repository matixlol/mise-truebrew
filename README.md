# mise-truebrew

A [mise](https://mise.jdx.dev) backend plugin that installs **Homebrew formulae
without Homebrew** — no `brew` binary, no `/opt/homebrew`, no sudo.
Inspired by [zerobrew](https://github.com/lucasgelfond/zerobrew).

```bash
mise plugin install truebrew https://github.com/mise-plugins/mise-truebrew
mise use truebrew:wget@1.25.0
mise exec -- wget --version
```

## How it works

For `truebrew:<formula>@<version>`, the plugin:

1. Fetches formula metadata from the `formulae.brew.sh` JSON API
   (same source as `brew info --json`).
2. Resolves the runtime dependency closure (minus `uses_from_macos` on macOS,
   plus Linux bottle variations; build/test/optional deps are skipped).
3. Picks the right prebuilt **bottle** for your platform
   (`arm64_tahoe` → `arm64_sequoia` → … on Apple Silicon, `sonoma`/`ventura`/…
   on Intel Macs, `arm64_linux`/`x86_64_linux` on Linux, with an `all` fallback).
   Newer-OS bottles are never selected on older systems.
4. Downloads the bottle blobs from GHCR (anonymous token auth) **in parallel**
   (up to 8 concurrent `curl` fetches, `TRUEBREW_JOBS` to tune) and **verifies
   the sha256** from the API before touching disk. Downloads are cached by hash.
5. Extracts into a user-owned shared prefix and **relocates** it the way
   `brew pour` does, in a single `lib/relocate.sh` invocation per keg (one
   subprocess no matter how many files the keg has):
   - Mach-O load commands holding `@@HOMEBREW_PREFIX@@` / `@@HOMEBREW_CELLAR@@`
     are rewritten with `install_name_tool` (text patching binaries is never done),
   - text files (pkgconfig, scripts, cmake, headers) get placeholder +
     hardcoded build-prefix replacement in one `perl` pass (this pass always
     runs, even for `:any_skip_relocation`-style bottles; static archives and
     other binaries are never text-patched),
   - absolute symlinks into the old prefix are re-pointed,
   - touched Mach-O files are re-signed with `codesign -f -s -`.
6. Links `opt/<name>` → `Cellar/<name>/<version>` and shims the keg's
   `bin`/`sbin` executables into mise's `install_path/bin`.

Verified end-to-end on macOS arm64, e.g. `wget` (7-keg closure incl.
`openssl@3` with its `openssl/3` GHCR layout, plus an `all`-tagged
`ca-certificates` bottle) with working TLS fetches.

## Layout

All state lives under one user-owned root (no sudo, no `/opt/homebrew`):

```
$TRUEBREW_ROOT/                  # ~/.local/share/mise-truebrew by default
  prefix/Cellar/<name>/<ver>/…   # poured kegs (shared, deduplicated)
  prefix/opt/<name>              # -> ../Cellar/<name>/<ver> (like brew)
  cache/blobs/<sha256>.tar.gz    # verified bottle downloads
~/.local/share/mise/installs/truebrew-<name>/<ver>/
  bin/*                          # symlinks into the keg
  truebrew.json                  # shim receipt
```

`mise uninstall` removes the shim; poured kegs/blobs stay cached for other
tools. To fully reset: `rm -rf ~/.local/share/mise-truebrew`.

## Usage

```bash
# browse / install
mise ls-remote truebrew:jq
mise install truebrew:jq@1.8.2
mise use truebrew:ripgrep@latest   # writes mise.toml, activates in project

# per-project pinning
cat mise.toml
# [tools]
# "truebrew:jq" = "1.8.2"
```

Versioned formulae (names containing `@`) work through `mise.toml`, where the
tool name and version are separate fields:

```toml
[tools]
"truebrew:openssl@3" = "3.6.4"
```

(On the CLI, mise itself parses `name@version` on `@`, so `mise ls-remote
'truebrew:openssl@3'` is ambiguous — prefer the config-file form above.)

### Options / environment

| Setting | Effect |
| --- | --- |
| `TRUEBREW_ROOT` env (or `root = "…"` tool option) | Override the shared root (prefix + caches). |
| `TRUEBREW_JOBS` env (or `MISE_JOBS`) | Max parallel bottle/metadata downloads (default 8, cap 16). |

`BackendExecEnv` puts the tool's `bin` first on `PATH` and additionally
provides `LDFLAGS` / `CPPFLAGS` / `PKG_CONFIG_PATH` / `MANPATH` pointing at the
shared prefix (so keg-only libraries like `openssl@3` are usable from
mise-managed toolchains), plus `LD_LIBRARY_PATH` on Linux.

## Limitations (v1, by design)

- **homebrew-core formulae only.** No casks, no third-party taps.
- **Bottles only, current stable only.** Like Homebrew's bottle hosting, old
  versions disappear; requesting a non-stable version errors clearly unless the
  keg was already poured (relink path). No `--build-from-source`
  (zerobrew's Ruby-DSL source builds are out of scope for a Lua backend).
- **macOS/Linux only.** Homebrew publishes no Windows bottles; the plugin
  errors fast on Windows.
- **Linux ELF relocation is best-effort**: text relocation + `LD_LIBRARY_PATH`
  always apply; exotic `RPATH`/interpreter layouts may need `patchelf` help.
  macOS relocation is fully implemented and tested.
- `post_install` steps, services, and `brew link` conflict semantics are not
  replicated — each mise tool gets an isolated shim instead.
- Search/discovery hooks (`backend_list_tools`, `backend_search_tools`) follow
  the plugin spec (curated catalog + formulae-index search), but older mise
  CLIs only query the static registry for `mise search`; browse
  [formulae.brew.sh](https://formulae.brew.sh) for names.

## Relationship to nearby projects

- [zerobrew](https://github.com/lucasgelfond/zerobrew) — the main inspiration:
  same bottle/placeholder/Cellar model, but as a standalone Rust package manager
  with CAS storage and source builds. truebrew brings the bottle-pour idea into
  mise's per-project tool model instead.
- `mise bootstrap packages brew:` (built into newer mise) — installs host
  system packages into the **canonical** Homebrew prefix. truebrew is the
  complementary `tools` backend: isolated, version-pinned installs under mise
  control, in a user-owned prefix.
- [mise backend plugin template](https://github.com/jdx/mise-backend-plugin-template)
  — structural starting point for this repo.

## Development

```bash
mise plugin link --force truebrew .
mise ls-remote truebrew:jq
./mise-tasks/test   # or: mise run test
```

Lua is 5.1 inside mise. The plugin deliberately uses only long-available Lua
module APIs (`http`, `json`, `cmd`, `file.exists`/`join_path`/`read`, `log`)
plus POSIX shell tools (`tar`, `shasum`/`sha256sum`, `otool`,
`install_name_tool`, `codesign`, `perl`, `grep`, `find`) so it also runs on
older mise releases that lack newer helpers like `file.list`/`file.stat`.

## License

MIT — see [LICENSE](LICENSE).
