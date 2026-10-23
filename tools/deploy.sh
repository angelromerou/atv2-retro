#!/bin/bash
# Copies .app bundles to the Apple TV, registers them, installs their home-screen entries
# (<App>.app/ATVMenu/*, see tools/make-menu.py) and launches the last one.
# Usage (Git Bash, WSL or Linux): tools/deploy.sh [--no-launch] path/to/Foo.app [more.app ...]
# Env: ATV_HOST (default 192.168.0.101), ATV_PASS (default alpine)
set -e
LAUNCH=1
[ "$1" = --no-launch ] && { LAUNCH=; shift; }
[ $# -gt 0 ] || { echo "usage: $0 [--no-launch] path/to/Foo.app [more.app ...]" >&2; exit 1; }
. "$(dirname "$0")/atv-ssh.sh"
SCRIPT=$(mktemp)
trap 'rm -f "$SCRIPT"' EXIT
echo 'menu=0; new=0' > "$SCRIPT"
for APP in "$@"; do
    APP=${APP%/}
    [ -f "$APP/Info.plist" ] || { echo "not an app bundle: $APP" >&2; exit 1; }
    NAME=$(basename "$APP")
    read -r ID EXE < <("$PY" -c "import plistlib,sys;d=plistlib.load(open(sys.argv[1],'rb'));print(d['CFBundleIdentifier'],d['CFBundleExecutable'])" "$APP/Info.plist" | tr -d '\r')
    atv_ssh "killall $EXE 2>/dev/null; rm -rf '/tmp/$NAME'" || true
    (cd "$(dirname "$APP")" && atv_scp -r "$NAME" root@$HOST:/tmp/)
    # remote steps for this app: install, then copy any changed home-screen entry into AppleTV.app
    cat >> "$SCRIPT" <<EOF
[ -d '/Applications/$NAME' ] || new=1
rm -rf '/Applications/$NAME'; mv '/tmp/$NAME' /Applications/; chmod 755 '/Applications/$NAME/$EXE'
# iOS 8 (ATV3) kills unsigned code; ldid's fake signature is enough
command -v ldid >/dev/null && for f in '/Applications/$NAME/$EXE' '/Applications/$NAME'/*.dylib; do [ ! -e "\$f" ] || ldid -S "\$f"; done
for f in '/Applications/$NAME'/ATVMenu/*; do
    [ -e "\$f" ] || continue
    t="/Applications/AppleTV.app/\$(basename "\$f")"
    cmp -s "\$f" "\$t" || { cp "\$f" "\$t"; menu=1; }
done
echo "installed $NAME"
EOF
done
cat >> "$SCRIPT" <<EOF
[ \$new = 1 ] && su mobile -c uicache
[ \$menu = 1 ] && { killall AppleTV; echo "home screen updated"; sleep 10; }
${LAUNCH:+atvopen $ID && echo "launched $ID"}
true
EOF
atv_ssh_script "$SCRIPT"
