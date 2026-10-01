#!/bin/bash
#
# ThermalForge Uninstall
# Removes the app bundle, its embedded privileged-helper registration, and user
# data. Idempotent: every step tolerates the thing already being absent.
#

APP_BUNDLE="/Applications/ThermalForge.app"
BUNDLE_CLI="$APP_BUNDLE/Contents/MacOS/thermalforge"
LABEL="com.thermalforge.daemon"
LEGACY_PLIST="/Library/LaunchDaemons/$LABEL.plist"
LEGACY_CLI="/usr/local/bin/thermalforge"

echo "Uninstalling ThermalForge..."

# (a) Quit the app first: its exit path resets the app-owned fan hold.
pkill -x ThermalForgeApp 2>/dev/null || true
sleep 1

# (b) Hand fans back to Apple through the still-running helper. Skip silently if
# the bundle or helper is already gone.
if [ -x "$BUNDLE_CLI" ]; then
    "$BUNDLE_CLI" auto >/dev/null 2>&1 || true
fi

# (c) Admin-authorized teardown of the privileged helper. Decide from the launchd
# LABEL and legacy on-disk artifacts only — never from a live process or socket,
# either of which can be absent while the job is still registered (a
# loaded-but-not-running job is exactly what bootout must clear).
NEEDS_ADMIN=0
if launchctl print "system/$LABEL" >/dev/null 2>&1; then NEEDS_ADMIN=1; fi
if [ -e "$LEGACY_PLIST" ]; then NEEDS_ADMIN=1; fi
if [ -e "$LEGACY_CLI" ]; then NEEDS_ADMIN=1; fi
if [ -e /var/run/thermalforge.sock ]; then NEEDS_ADMIN=1; fi

if [ "$NEEDS_ADMIN" = 1 ]; then
    echo "Removing the privileged background helper (administrator authorization required)..."
    TEARDOWN=$(mktemp "${TMPDIR:-/tmp}/thermalforge-teardown.XXXXXX") || exit 1
    cat > "$TEARDOWN" <<'EOS'
#!/bin/sh
# Runs as root via osascript. Must exit NONZERO if the job cannot be confirmed
# gone, so the caller aborts before deleting the bundle (whose CLI is needed to
# retry the fan reset).
LABEL=com.thermalforge.daemon
FAIL=0

# Bootout only when the job is actually registered: a missing job is the
# idempotent "already gone" case, not a failure.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    if ! launchctl bootout "system/$LABEL"; then
        echo "ERROR: launchctl bootout system/$LABEL failed" >&2
        FAIL=1
    fi
fi

# Wait up to 10s for the helper process to actually exit (KeepAlive keeps it up
# until the bootout takes effect).
i=0
while [ "$i" -lt 20 ]; do
    pgrep -f '[t]hermalforge-helper' >/dev/null 2>&1 || break
    sleep 0.5
    i=$((i + 1))
done
if pgrep -f '[t]hermalforge-helper' >/dev/null 2>&1; then
    echo "ERROR: thermalforge-helper is still running after bootout" >&2
    FAIL=1
fi

# The job must be gone from launchd before we tear anything else down.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "ERROR: $LABEL is still registered after bootout" >&2
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    echo "ERROR: privileged helper teardown failed; aborting before bundle removal" >&2
    exit 1
fi

# Only now that the job is confirmed gone: remove the socket and any legacy
# root-owned install left by older versions.
rm -f /var/run/thermalforge.sock
rm -f /Library/LaunchDaemons/$LABEL.plist
rm -f /usr/local/bin/thermalforge
exit 0
EOS
    chmod 700 "$TEARDOWN"
    if ! osascript -e "do shell script \"/bin/sh '$TEARDOWN'\" with administrator privileges"; then
        rm -f "$TEARDOWN"
        echo ""
        echo "ERROR: the privileged background helper could not be removed"
        echo "       (administrator authorization cancelled, or teardown failed)."
        echo "       The app bundle was left in place so its CLI can retry the reset."
        echo "       Re-run ./uninstall.sh to finish removing it."
        exit 1
    fi
    rm -f "$TEARDOWN"

    # Belt-and-suspenders: the admin script verified this, but confirm from the
    # parent before deleting the bundle.
    if launchctl print "system/$LABEL" >/dev/null 2>&1; then
        echo "ERROR: $LABEL is still registered after teardown; aborting before bundle removal."
        exit 1
    fi
fi

# (d) Remove the bundle and user data. The bundle is user-owned in the new layout,
# so no admin is needed; a root-owned legacy bundle is the one case that can fail.
rm -rf "$APP_BUNDLE" 2>/dev/null || echo "WARNING: could not remove $APP_BUNDLE (root-owned legacy bundle?)."
rm -rf "$HOME/Library/Logs/ThermalForge"
rm -rf "$HOME/Library/Application Support/ThermalForge"

# (e) Final note.
echo ""
echo "ThermalForge removed."
echo "The ThermalForge entry under System Settings > General > Login Items & Extensions"
echo "disappears with the app bundle."
