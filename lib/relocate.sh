#!/bin/sh
# truebrew bottle relocation: rewrite Homebrew build-prefix placeholders to a
# user-owned prefix. Runs as ONE shell invocation (a single mise cmd.exec) so
# per-call bridge overhead is paid once no matter how many files a keg has.
#
# Usage: relocate.sh <keg_dir> <prefix> <cellar>
# Prints: TRUEBREW_RELOCATE macho=<n> text=<m> skipped=<k>
#
# Steps mirror `brew pour`: Mach-O load commands via install_name_tool (never
# text-patched), placeholder + hardcoded-prefix replacement in text files only
# (single perl pass; archives/binaries are never touched), absolute symlinks
# into the old prefix re-pointed, touched Mach-O re-signed with codesign.
set -u
keg="$1"
prefix="$2"
cellar="$3"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/truebrew-reloc.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM

os=$(uname -s)

esc() {
    printf '%s' "$1" | sed 's/[&|\\@$]/\\&/g'
}
esc_prefix=$(esc "$prefix")
esc_cellar=$(esc "$cellar")
subst() {
    printf '%s' "$1" | sed -e "s|@@HOMEBREW_PREFIX@@|$esc_prefix|g" -e "s|@@HOMEBREW_CELLAR@@|$esc_cellar|g"
}

macho_n=0
text_n=0
skipped_n=0

# 1. One recursive scan for every relocatable string.
grep -rl -e '@@HOMEBREW_PREFIX@@' -e '@@HOMEBREW_CELLAR@@' -e '/opt/homebrew/Cellar' -e '/home/linuxbrew/.linuxbrew/Cellar' "$keg" 2>/dev/null >"$tmp/cands" || true

# 2-4. Classify each hit and act on it.
if [ -s "$tmp/cands" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        kind=$(file -b "$f")
        case "$kind" in
        *Mach-O*)
            if [ "$os" != "Darwin" ]; then
                echo "truebrew: Mach-O file on non-macOS: $f" >&2
                continue
            fi
            otool -L "$f" | awk 'NR>1 {print $1}' | grep '@@HOMEBREW' >"$tmp/refs" || true
            touched=0
            if [ -s "$tmp/refs" ]; then
                while IFS= read -r old; do
                    [ -n "$old" ] || continue
                    install_name_tool -change "$old" "$(subst "$old")" "$f" || exit 1
                    touched=1
                done <"$tmp/refs"
            fi
            id=$(otool -D "$f" | tail -n 1) || exit 1
            case "$id" in
            *@@HOMEBREW*)
                install_name_tool -id "$(subst "$id")" "$f" || exit 1
                touched=1
                ;;
            esac
            if [ "$touched" = 1 ]; then
                printf '%s\n' "$f" >>"$tmp/changed"
                macho_n=$((macho_n + 1))
            fi
            ;;
        *ELF*)
            echo "truebrew: ELF skipped, needs patchelf review: $f" >&2
            ;;
        *text* | *script* | *JSON* | *XML* | *source*)
            printf '%s\n' "$f" >>"$tmp/texts"
            ;;
        *)
            # Archives, data, fonts, certs...: never perl-patch binaries.
            printf '%s: %s\n' "$f" "$kind" >>"$tmp/skipped"
            ;;
        esac
    done <"$tmp/cands"
fi

# 5. Text pass: one perl invocation for all text files.
if [ -s "$tmp/texts" ]; then
    set -- dummyplaceholder
    shift
    while IFS= read -r f; do set -- "$@" "$f"; done <"$tmp/texts"
    # shellcheck disable=SC2128
    if [ $# -gt 0 ]; then
        perl -pi -e "s|\@\@HOMEBREW_PREFIX\@\@|$esc_prefix|g; s|\@\@HOMEBREW_CELLAR\@\@|$esc_cellar|g; s|/opt/homebrew|$esc_prefix|g; s|/usr/local|$esc_prefix|g; s|/home/linuxbrew/.linuxbrew|$esc_prefix|g" "$@" || exit 1
        text_n=$#
    fi
fi

# Restore positional params (keg/prefix/cellar) clobbered above.
set -- "$keg" "$prefix" "$cellar"
keg="$1"
prefix="$2"
cellar="$3"

# 6. Re-point absolute symlinks into the old Homebrew prefix. Kegs can ship
#    thousands of (relative) symlinks, so pre-filter with find -lname instead
#    of forking readlink per link; the loop below usually runs zero times.
find "$keg" -type l \( -lname '/opt/homebrew/*' -o -lname '/usr/local/Cellar/*' -o -lname '/usr/local/opt/*' -o -lname '/home/linuxbrew/.linuxbrew/*' \) -print0 | while IFS= read -r -d '' l; do
    t=$(readlink "$l")
    case "$t" in
    /opt/homebrew/* | /usr/local/Cellar/* | /usr/local/opt/* | /home/linuxbrew/.linuxbrew/*)
        n="$prefix${t#/opt/homebrew}"
        # crude but safe: only rewrite when target exists under new prefix
        if [ -e "$n" ]; then
            ln -sfn "$n" "$l"
        fi
        ;;
    esac
done

# 7. Re-sign touched Mach-O (required on arm64 macOS).
if [ -s "$tmp/changed" ] && [ "$os" = "Darwin" ]; then
    set -- dummyplaceholder
    shift
    while IFS= read -r f; do set -- "$@" "$f"; done <"$tmp/changed"
    # shellcheck disable=SC2128
    if [ $# -gt 0 ]; then
        codesign -f -s - "$@" || exit 1
    fi
fi

if [ -s "$tmp/skipped" ]; then
    skipped_n=$(wc -l <"$tmp/skipped" | tr -d ' ')
fi
echo "TRUEBREW_RELOCATE macho=$macho_n text=$text_n skipped=$skipped_n"
