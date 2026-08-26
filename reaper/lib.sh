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
# Started fresh on every run -- see the note inside about why its data must
# not live on the dataset `reaper reset` rolls back.
broker_up() {
    if [ ! -x /usr/local/sbin/mosquitto ]; then
        say "installing mosquitto"
        env ASSUME_ALWAYS_YES=yes pkg install -y mosquitto >/dev/null \
            || die "could not install mosquitto"
    fi

    # persistence OFF, and nothing of the broker's under $REAPER_STATE.
    #
    # `reaper test` is sync -> build -> RESET -> run, and reset rolls back the
    # tank/state dataset. A broker still running from a previous run with its
    # data directory on that dataset has the filesystem pulled out from under
    # it: it keeps accepting TCP connections and then drops them, which
    # surfaces upstream as tortoise crashing on {:error, :einval} from a
    # socket that is already dead. The MQTT library was the victim, not the
    # cause.
    #
    # Nothing here needs broker-side persistence yet. When tier 6's
    # hostile-start half lands (M6/M7) and retained state matters, the broker
    # must be stopped before reset rather than moved back onto tank/state.
    # Run as root. mosquitto drops privileges to 'mosquitto' or, absent that
    # user, to 'nobody' -- which then cannot open a root-created log file, so
    # log_dest silently writes nothing and the log looks like a broker no
    # client ever contacted. This is a disposable single-tenant guest; there is
    # nothing here to protect from the broker.
    rm -f /var/db/mosquitto.log
    mkdir -p /var/db/mosquitto
    cat > /var/db/mosquitto.conf <<EOF
user root
listener 1883 127.0.0.1
allow_anonymous true
persistence false
log_type all
connection_messages true
# log_dest, not a shell redirect. `mosquitto -d` daemonises and closes stderr,
# so redirecting its stdout captures the two lines printed before the fork and
# nothing afterwards -- producing a log file that looks like a broker no client
# ever contacted, whatever actually happened.
log_dest file /var/db/mosquitto.log
log_timestamp_format %Y-%m-%dT%H:%M:%S
EOF

    # Always restart rather than reusing whatever is listening. A broker left
    # over from a previous run may have survived a `reaper reset` with its
    # working directory gone: it still accepts TCP and then drops the
    # connection, so a liveness check on the port reports a healthy broker that
    # is anything but. With persistence off, restarting costs nothing.
    if broker_listening; then
        say "broker already listening -- restarting it to be sure it is healthy"
        broker_down
        i=0
        while broker_listening && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
    fi

    # Redirect, and detach from this job's streams. `mosquitto -d` daemonises
    # but inherits stdout/stderr, so the pipe reaper is reading stays open
    # after this script exits -- reaper then waits on a stream that will never
    # close and gives up after session.io_timeout with "stopped responding",
    # which reads like a hung test rather than a held file descriptor.
    /usr/local/sbin/mosquitto -c /var/db/mosquitto.conf -d \
        > /var/db/mosquitto.startup.log 2>&1 < /dev/null \
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
    pkill mosquitto 2>/dev/null || true
}
