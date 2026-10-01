#!/bin/bash
#
# ThermalForge Uninstall
# Removes the app bundle, its embedded privileged-helper registration, and user
# data. Idempotent: every step tolerates the thing already being absent.
#

APP_BUNDLE="/Applications/ThermalForge.app"
BUNDLE_CLI="$APP_BUNDLE/Contents/MacOS/thermalforge"

echo "Uninstalling ThermalForge..."

# (a) Quit the app first: its exit path resets the app-owned fan hold.
pkill -x ThermalForgeApp 2>/dev/null || true
sleep 1

# (b) Hand fans back to Apple through the still-running helper. Skip silently if
# the bundle or helper is already gone.
if [ -x "$BUNDLE_CLI" ]; then
    "$BUNDLE_CLI" auto >/dev/null 2>&1 || true
fi

# (c) Admin-authorized teardown of the privileged helper. Prompt only when there
# is something to remove, so a clean machine never shows a password dialog.
NEEDS_ADMIN=0
[ -e /var/run/thermalforge.sock ] && NEEDS_ADMIN=1
[ -e /Library/LaunchDaemons/com.thermalforge.daemon.plist ] && NEEDS_ADMIN=1
[ -e /usr/local/bin/thermalforge ] && NEEDS_ADMIN=1
pgrep -f '[t]hermalforge-helper' >/dev/null 2>&1 && NEEDS_ADMIN=1

if [ "$NEEDS_ADMIN" = 1 ]; then
    echo "Removing the privileged background helper (administrator authorization required)..."
    TEARDOWN=$(mktemp "${TMPDIR:-/tmp}/thermalforge-teardown.XXXXXX") || exit 1
    cat > "$TEARDOWN" <<'EOS'
#!/bin/sh
# Stop the SMAppService helper, then wait for its process to actually exit.
launchctl bootout system/com.thermalforge.daemon 2>/dev/null || true
i=0
while [ "$i" -lt 20 ]; do
    pgrep -f '[t]hermalforge-helper' >/dev/null 2>&1 || break
    sleep 0.5
    i=$((i + 1))
done
# Remove the socket and any legacy root-owned install left by older versions.
rm -f /var/run/thermalforge.sock
rm -f /Library/LaunchDaemons/com.thermalforge.daemon.plist
rm -f /usr/local/bin/thermalforge
EOS
    chmod 700 "$TEARDOWN"
    if ! osascript -e "do shell script \"/bin/sh '$TEARDOWN'\" with administrator privileges"; then
        echo "WARNING: the background helper could not be removed (authorization cancelled?)."
        echo "         Re-run ./uninstall.sh to finish removing it."
    fi
    rm -f "$TEARDOWN"
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
