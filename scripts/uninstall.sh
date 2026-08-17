#!/bin/sh
# uninstall.sh [-x] [--keep-backups]
#
# Reverses everything the setup steps install, in this order:
#   1. Quit a running ClaudeCompanion.app.
#   2. Remove the companion hooks from ~/.claude/settings.json
#      (delegates to install-hooks.mjs -r -x — leaves your other hooks intact).
#   3. Delete the per-session state dir ~/.claude/companion-state/.
#   4. Delete the built ClaudeCompanion.app bundle and the .build artifacts.
#   5. Remove the "Claude Companion Local" self-signed identity from the login
#      keychain (created by setup-signing.sh).
#   6. Optionally remove settings.json.companion-bak-* backups (see below).
#
# Defaults to a DRY RUN (prints what it would do). Pass -x to actually remove.
# Pass --keep-backups to leave the settings.json backups on disk.
#
# What it CAN'T remove (macOS gives no CLI for it) — do these by hand:
#   • System Settings → Privacy & Security → Accessibility  → remove "Claude Companion"
#   • System Settings → Privacy & Security → Automation      → remove "Claude Companion"

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/ClaudeCompanion.app"
BUILD="$ROOT/.build"
SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="${CLAUDE_COMPANION_STATE_DIR:-$HOME/.claude/companion-state}"
IDENTITY="Claude Companion Local"

EXECUTE=0
KEEP_BACKUPS=0
for arg in "$@"; do
    case "$arg" in
        -x) EXECUTE=1 ;;
        --keep-backups) KEEP_BACKUPS=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [ "$EXECUTE" -ne 1 ]; then
    echo "DRY RUN — nothing will be removed. Re-run with -x to apply."
    echo
fi

# run <human-description> <command...>  — echo, then run only when executing.
run() {
    desc="$1"; shift
    echo "• $desc"
    [ "$EXECUTE" -eq 1 ] && "$@" || true
}

# 1. Quit the running app so it stops re-creating state files mid-uninstall.
if pgrep -x ClaudeCompanion >/dev/null 2>&1; then
    run "Quit running ClaudeCompanion" pkill -x ClaudeCompanion
else
    echo "• ClaudeCompanion not running — skip"
fi

# 2. Remove the companion hooks from settings.json (idempotent; keeps others).
if [ -f "$SETTINGS" ]; then
    if [ "$EXECUTE" -eq 1 ]; then
        echo "• Remove companion hooks from $SETTINGS"
        node "$ROOT/scripts/install-hooks.mjs" -r -x
    else
        echo "• Would remove companion hooks from $SETTINGS"
    fi
else
    echo "• No $SETTINGS — skip hook removal"
fi

# 3. Per-session state directory written by the hook.
if [ -d "$STATE_DIR" ]; then
    run "Delete state dir $STATE_DIR" rm -rf "$STATE_DIR"
else
    echo "• No state dir at $STATE_DIR — skip"
fi

# 4. Build outputs.
if [ -d "$APP" ]; then
    run "Delete app bundle $APP" rm -rf "$APP"
else
    echo "• No app bundle at $APP — skip"
fi
if [ -d "$BUILD" ]; then
    run "Delete Swift build artifacts $BUILD" rm -rf "$BUILD"
else
    echo "• No .build dir at $BUILD — skip"
fi

# 5. Self-signed code-signing identity in the login keychain.
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    if [ "$EXECUTE" -eq 1 ]; then
        echo "• Remove signing identity '$IDENTITY' from keychain"
        # Delete the identity (private key) and the certificate; ignore if one
        # of them is already gone.
        security delete-identity -c "$IDENTITY" >/dev/null 2>&1 || true
        security delete-certificate -c "$IDENTITY" >/dev/null 2>&1 || true
    else
        echo "• Would remove signing identity '$IDENTITY' from keychain"
    fi
else
    echo "• No signing identity '$IDENTITY' — skip"
fi

# 6. settings.json backups created by install-hooks.mjs (opt-out with --keep-backups).
BAKS=$(ls "$SETTINGS".companion-bak-* 2>/dev/null || true)
if [ -n "$BAKS" ]; then
    if [ "$KEEP_BACKUPS" -eq 1 ]; then
        echo "• Keeping settings backups (--keep-backups):"
        echo "$BAKS" | sed 's/^/    /'
    else
        run "Delete settings backups ($SETTINGS.companion-bak-*)" \
            sh -c 'rm -f "$0".companion-bak-*' "$SETTINGS"
    fi
else
    echo "• No settings backups — skip"
fi

echo
if [ "$EXECUTE" -eq 1 ]; then
    echo "Done. Restart any running Claude Code sessions so they drop the hooks."
else
    echo "Re-run with -x to apply."
fi
echo "Remember to remove 'Claude Companion' from System Settings →"
echo "Privacy & Security → Accessibility and → Automation (no CLI for that)."
