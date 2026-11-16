#!/bin/zsh
# Builds FaNG (with its extension) and installs it on this Mac and on every connected iPhone and iPad
# with Developer Mode on, then starts it. Devices are found at run time, so a newly paired one is
# included automatically. Signing is automatic (free Personal Team: profiles last 7 days, and a run
# renews them).
#
#   scripts/deploy.sh            Mac and all connected iOS devices
#   scripts/deploy.sh mac        Mac only
#   scripts/deploy.sh ios        iOS devices only
set -euo pipefail

cd "${0:A:h}/.."
project=FaNG.xcodeproj
scheme=FaNG
bundle=com.rlx.fang
target=${1:-all}

# Builds for a destination; returns non-zero (after printing the errors) if the build failed.
build() {
    local log
    log=$(xcodebuild -project $project -scheme $scheme -configuration Debug -destination "$1" \
        -allowProvisioningUpdates build 2>&1)
    echo "$log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
    echo "$log" | grep -q "BUILD SUCCEEDED"
}

products() {
    xcodebuild -project $project -scheme $scheme -configuration Debug -destination "$1" \
        -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *TARGET_BUILD_DIR =/ { print $2; exit }'
}

if [[ $target == all || $target == mac ]]; then
    echo "== Mac"
    if build 'platform=macOS'; then
        app="$(products 'platform=macOS')/FaNG.app"
        pkill -x FaNG || true
        sleep 1
        # Re-register the fresh build so LaunchServices (and with it the Dock) shows its current icon,
        # not one cached for an older build or for another copy with the same bundle ID.
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
        open "$app"
        echo "started $app"
    fi
fi

if [[ $target == all || $target == ios ]]; then
    json=$(mktemp)
    trap 'rm -f $json' EXIT
    xcrun devicectl list devices --json-output "$json" >/dev/null
    devices=($(python3 -I - "$json" <<'EOF'
import json, sys
for device in json.load(open(sys.argv[1]))["result"]["devices"]:
    hardware = device.get("hardwareProperties", {})
    if (hardware.get("platform") == "iOS"
            # "disconnected" is a paired device on the network: devicectl opens the tunnel when it's used.
            and device.get("connectionProperties", {}).get("tunnelState") in ("connected", "disconnected")
            and device.get("deviceProperties", {}).get("developerModeStatus") == "enabled"):
        print(hardware["udid"])
EOF
    ))
    if (( ${#devices} == 0 )); then
        echo "== no reachable iPhone or iPad with Developer Mode on (cable or same network)"
    fi
    for udid in $devices; do
        echo "== $udid"
        if ! build "id=$udid"; then
            echo "not installed: the build failed (a new device needs one run from Xcode to join the provisioning profile)"
            continue
        fi
        app="$(products "id=$udid")/FaNG.app"
        xcrun devicectl device install app --device $udid "$app" >/dev/null && echo "installed"
        # Files caches which actions extensions exist: reinstalled while it's open, it can keep showing none of
        # FaNG's (Versions…, Copy To…, Move To…) until it's restarted.
        echo "if Files is open on it, force-quit and reopen it so it sees FaNG's actions"
        if xcrun devicectl device process launch --device $udid --terminate-existing $bundle >/dev/null 2>&1; then
            echo "started"
        else
            echo "not started (device locked?); open it from the home screen"
        fi
    done
fi
