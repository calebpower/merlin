#!/bin/sh
#
# merlin's reaper build verb.
#
# Runs as root on a freebsd-15.1 guest, in $REAPER_WORK, under /bin/sh.
#
# There is no `tee` anywhere in this file, and no pipeline whose exit status
# matters. /bin/sh has no `pipefail`, so `cmd | tee log` exits with tee's
# status and a failing build reads as a pass. Output goes to stdout, which
# reaper captures; artifacts and machine-readable records go to $REAPER_OUT.

set -eu

# Expected toolchain. `exec = "host"` means the manifest cannot pin this, so we
# assert it instead -- see the comment in .reaper.toml. Majors only: a patch
# bump is fine, an OTP major bump is not, because that is exactly the drift
# that left elixir-devel-1.20.2 unable to boot against OTP 27 on the
# development workstation.
WANT_OTP_MAJOR=28
WANT_ELIXIR_MINOR=1.19

say() { printf '==> %s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Caches. Load-bearing, not an optimisation: the guest root disk has ~3.3 GiB
# free and Hex plus _build will fill it. Every path Elixir writes to by default
# lives under $HOME or the tree; all of them are redirected onto the pool here.
# ---------------------------------------------------------------------------
: "${REAPER_OUT:?not running under reaper}"
: "${REAPER_CACHE_PKG:?}" ; : "${REAPER_CACHE_HEX:?}"
: "${REAPER_CACHE_MIX:?}" ; : "${REAPER_CACHE_DEPS:?}"
: "${REAPER_CACHE_BUILD:?}"

export PKG_CACHEDIR="$REAPER_CACHE_PKG"
export HEX_HOME="$REAPER_CACHE_HEX"
export MIX_HOME="$REAPER_CACHE_MIX"
export MIX_DEPS_PATH="$REAPER_CACHE_DEPS"
export MIX_BUILD_ROOT="$REAPER_CACHE_BUILD"
export MIX_ENV=prod

# elixir_make drives the exqlite NIF. FreeBSD's base `make` is bmake; the
# bundled SQLite Makefile expects GNU make, so name it explicitly rather than
# finding out three minutes into a build.
export MAKE=gmake

mkdir -p "$PKG_CACHEDIR" "$HEX_HOME" "$MIX_HOME" "$MIX_DEPS_PATH" "$MIX_BUILD_ROOT"

# ---------------------------------------------------------------------------
# Toolchain. The freebsd-15.1 template is a pkgbase install: clang, ZFS and the
# whole base userland are present, but no Erlang, no Elixir, no gmake. Egress
# works, so the tenant installs what it needs. Idempotent, so a warm session
# pays this once rather than every build.
# ---------------------------------------------------------------------------
if [ ! -x /usr/local/bin/elixir ] || [ ! -x /usr/local/bin/erl ]; then
    say "installing toolchain (erlang, elixir, gmake)"
    env ASSUME_ALWAYS_YES=yes pkg install -y erlang elixir gmake \
        || die "pkg install failed -- check guest egress to the FreeBSD mirror"
else
    say "toolchain already present, skipping install"
fi

# ---------------------------------------------------------------------------
# Assert what we actually got. This is the whole compensation for host-exec not
# pinning the toolchain, so it fails the build rather than warning.
# ---------------------------------------------------------------------------
otp_major=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null || true)
[ -n "$otp_major" ] || die "erl did not report an OTP release"

elixir_ver=$(elixir --version 2>/dev/null | sed -n 's/^Elixir \([0-9][0-9.]*\).*/\1/p' | head -1 || true)
[ -n "$elixir_ver" ] || die "elixir did not report a version (an OTP/Elixir mismatch looks exactly like this)"

elixir_minor=$(printf '%s' "$elixir_ver" | cut -d. -f1,2)

say "OTP $otp_major, Elixir $elixir_ver"

[ "$otp_major" = "$WANT_OTP_MAJOR" ] \
    || die "OTP $otp_major, expected $WANT_OTP_MAJOR. The release bundles ERTS; a major change is a different artifact."
[ "$elixir_minor" = "$WANT_ELIXIR_MINOR" ] \
    || die "Elixir $elixir_ver, expected $WANT_ELIXIR_MINOR.x"

# Record it. A build log that does not say which toolchain produced the
# artifact cannot be used to explain the artifact later.
{
    printf 'otp_release=%s\n' "$otp_major"
    printf 'elixir_version=%s\n' "$elixir_ver"
    printf 'freebsd_version=%s\n' "$(freebsd-version -kru | tr '\n' ' ')"
    printf 'uname=%s\n' "$(uname -a)"
} > "$REAPER_OUT/toolchain.txt"

# ---------------------------------------------------------------------------
# Build.
# ---------------------------------------------------------------------------
say "hex + rebar"
mix local.hex --force --if-missing
mix local.rebar --force --if-missing

say "deps"
mix deps.get

say "compile (warnings are errors)"
mix compile --warnings-as-errors

# ---------------------------------------------------------------------------
# Static analysis, as a build gate rather than a tier.
#
# It does not belong in the tiered battery: the tiers are a portfolio of
# ORACLES, each answering "did this behave correctly", and dialyzer answers a
# different question entirely -- whether the code is self-consistent about the
# shapes it passes around. Something that cannot type-check should not reach
# the point of being tested, in the same way something that cannot compile
# should not.
#
# The PLT lives in the build cache. First run costs minutes; every run after
# it costs seconds.
# ---------------------------------------------------------------------------
say "dialyzer"
MIX_ENV=test mix dialyzer --format dialyxir

say "release"
mix release --overwrite

# Hand the artifact back. Only out/ is pulled to the workstation, so anything
# not copied here does not survive the session.
tarball=$(find "$MIX_BUILD_ROOT" -name 'merlin-*.tar.gz' -type f 2>/dev/null | head -1 || true)
if [ -n "$tarball" ]; then
    cp "$tarball" "$REAPER_OUT/"
    say "release tarball -> $REAPER_OUT/$(basename "$tarball")"
else
    die "mix release produced no tarball; expected one under $MIX_BUILD_ROOT"
fi

say "build ok"
