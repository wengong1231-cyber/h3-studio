#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
APP_DIR="$TASK_ROOT/build/release/镜生 H3.app"
BIN="$APP_DIR/Contents/MacOS/WanshenjiH3Studio"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")" == "0.4.19" ]] || { print -u2 "Expected verified 0.4.19 candidate."; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")" == "26" ]] || { print -u2 "Expected build 26."; exit 1; }
case "${1:---plan}" in
  --plan)
    exec "$BIN" --installation-plan --legacy-workspace "$TASK_ROOT/Data"
    ;;
  --install)
    # The native installer checks the old queue/global locks and refuses an
    # active app. It preserves and verifies the previous fixed-identity bundle.
    exec "$BIN" --install-user-app --apply --legacy-workspace "$TASK_ROOT/Data"
    ;;
  --install-with-initial-signing-migration)
    exec "$BIN" --install-user-app --apply --allow-signing-identity-migration --legacy-workspace "$TASK_ROOT/Data"
    ;;
  *)
    print -u2 "Usage: ./scripts/install-user.sh --plan | --install | --install-with-initial-signing-migration"
    exit 2
    ;;
esac
