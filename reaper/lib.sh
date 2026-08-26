# shellcheck shell=sh
#
# Shared helpers for merlin's reaper verbs. Sourced, never executed.
#
# No pipelines whose exit status matters -- /bin/sh has no `pipefail`.

say()  { printf '==> %s\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# Export the cache redirections. Called by every verb, because a verb that
# forgets one of these writes to $HOME on a root disk with ~3.3 GiB free and
# the failure surfaces later as something unrelated running out of space.
merlin_export_caches() {
    : "${REAPER_CACHE_PKG:?}"   ; : "${REAPER_CACHE_HEX:?}"
    : "${REAPER_CACHE_MIX:?}"   ; : "${REAPER_CACHE_DEPS:?}"
    : "${REAPER_CACHE_BUILD:?}"

    export PKG_CACHEDIR="$REAPER_CACHE_PKG"
    export HEX_HOME="$REAPER_CACHE_HEX"
    export MIX_HOME="$REAPER_CACHE_MIX"
    export MIX_DEPS_PATH="$REAPER_CACHE_DEPS"
    export MIX_BUILD_ROOT="$REAPER_CACHE_BUILD"
    export MAKE=gmake
}

# A real broker. Tiers 6 and above use this rather than a mock, and its
# persistence sits under $REAPER_STATE so `reaper reset` rolls it back.
broker_up() {
    if [ ! -x /usr/local/sbin/mosquitto ]; then
        say "installing mosquitto"
        env ASSUME_ALWAYS_YES=yes pkg install -y mosquitto >/dev/null \
            || die "could not install mosquitto"
    fi

    mkdir -p "$REAPER_STATE/mosquitto"
    cat > "$REAPER_STATE/mosquitto.conf" <<EOF
listener 1883 127.0.0.1
allow_anonymous true
persistence true
persistence_location $REAPER_STATE/mosquitto/
EOF

    if broker_listening; then
        say "broker already up"
        return 0
    fi

    # Redirect, and detach from this job's streams. `mosquitto -d` daemonises
    # but inherits stdout/stderr, so the pipe reaper is reading stays open
    # after this script exits -- reaper then waits on a stream that will never
    # close and gives up after session.io_timeout with "stopped responding",
    # which reads like a hung test rather than a held file descriptor.
    /usr/local/sbin/mosquitto -c "$REAPER_STATE/mosquitto.conf" -d \
        > "$REAPER_STATE/mosquitto.log" 2>&1 < /dev/null \
        || die "mosquitto failed to start"

    # Poll for the port rather than sleeping a guessed interval.
    i=0
    while [ "$i" -lt 100 ]; do
        broker_listening && return 0
        i=$((i + 1))
        sleep 0.1
    done
    die "mosquitto did not begin listening on 127.0.0.1:1883"
}

broker_listening() {
    sockstat -4l 2>/dev/null | grep -q '127\.0\.0\.1:1883'
}

broker_down() {
    pkill -F "$REAPER_STATE/mosquitto.pid" 2>/dev/null || pkill mosquitto 2>/dev/null || true
}
