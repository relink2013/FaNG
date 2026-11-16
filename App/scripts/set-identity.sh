#!/bin/zsh
# Gives your copy of FaNG its own bundle identifiers and signing team, so Xcode can sign it with your Apple ID.
# Bundle identifiers are unique per developer account: the ones in the repo (com.rlx.fang…) belong to another
# account, so every copy needs its own. Run it once after cloning; running it again with new values works too.
#
#   scripts/set-identity.sh com.yourname.fang            # team picked from your signing certificate
#   scripts/set-identity.sh com.yourname.fang ABCDE12345 # or given
#
# It replaces the identifier prefix everywhere it appears (app, extensions, App Group, keychain names) and sets
# the development team in the project.
set -euo pipefail
cd "${0:A:h}/.."

prefix=${1:-}
team=${2:-}
if [[ ! $prefix =~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$' ]]; then
    echo "usage: scripts/set-identity.sh com.yourname.fang [TEAMID]" >&2
    echo "  (lowercase letters, digits and dashes, with dots between, like com.yourname.fang)" >&2
    exit 2
fi

# The prefix in use now: the app's own bundle identifier.
current=$(sed -n 's/.*"PRODUCT_BUNDLE_IDENTIFIER": "\([^"]*\)".*/\1/p' FaNG.xcodeproj/project.xcproj |
    awk 'NR == 1 || length($0) < length(shortest) { shortest = $0 } END { print shortest }')
[[ -n $current ]] || { echo "Couldn't find the current bundle identifier in the project." >&2; exit 1; }

if [[ -z $team ]]; then
    # The team (organizational unit) of each "Apple Development" certificate in the keychain.
    teams=($(security find-certificate -a -c "Apple Development" -p 2>/dev/null |
        awk '/BEGIN CERT/ { cert = "" } { cert = cert $0 "\n" } /END CERT/ { printf "%s", cert | "openssl x509 -noout -subject -nameopt multiline"; close("openssl x509 -noout -subject -nameopt multiline") }' |
        sed -n 's/^ *organizationalUnitName *= *//p' | sort -u))
    if (( ${#teams} == 1 )); then
        team=${teams[1]}
        echo "Signing team: $team (from your Apple Development certificate)"
    elif (( ${#teams} > 1 )); then
        echo "You have certificates for several teams: ${teams[*]}" >&2
        echo "Run it again with the one to use: scripts/set-identity.sh $prefix TEAMID" >&2
        exit 1
    else
        echo "No signing certificate found yet: pick your team in Xcode (each target's Signing & Capabilities)."
    fi
fi

if [[ $current != "$prefix" ]]; then
    escaped_current=${current//./\\.}
    files=($(grep -rlF "$current" FaNG.xcodeproj FaNG FaNGProvider FaNGActions FaNGKit FaNGTests FaNGUITests scripts \
        --exclude set-identity.sh))
    LC_ALL=C sed -i '' "s/$escaped_current/$prefix/g" $files
    echo "Bundle identifiers: $current → $prefix (${#files} files)"
fi
if [[ -n $team ]]; then
    LC_ALL=C sed -i '' "s/\"DEVELOPMENT_TEAM\": \"[^\"]*\"/\"DEVELOPMENT_TEAM\": \"$team\"/" FaNG.xcodeproj/project.xcproj
fi
echo "Done. Open FaNG.xcodeproj in Xcode, or run scripts/deploy.sh."
