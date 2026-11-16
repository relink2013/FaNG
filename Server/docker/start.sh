#!/bin/bash
# Starts FaNG's Samba, fang-storaged and fang-api. The container stops when any of them stops.
#
# /config/shares.conf  one share a line: name|path in the container|create mask|directory mask
# /config/users        FaNG users, name:uid (managed with fang-user); Samba's passwords are in
#                      /config/samba/private, so they survive rebuilds
set -euo pipefail

mkdir -p /config/served /config/samba/private /config/samba/state /config/samba/cache /config/tls /run/samba/lock /run/fang /run/fang/shares
chmod 755 /config
chmod 700 /config/samba/private
touch /config/users
# The shares file (shares are added in the admin page); a new server starts with none.
[[ -e /config/shares.conf ]] || : > /config/shares.conf
# The admin page's admins: the first FaNG user, until someone changes it there (fang-user does the same
# for a new server's first user).
touch /config/admins
if ! grep -q '[^[:space:]]' /config/admins; then
    head -1 /config/users | cut -d: -f1 > /config/admins
fi
chmod 644 /config/users /config/shares.conf /config/admins

# The API's certificate, made once. Clients pin it by the fingerprint published in fang$ below.
if [[ ! -f /config/tls/cert.pem ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=FaNG" \
        -keyout /config/tls/key.pem -out /config/tls/cert.pem 2>/dev/null
fi
chown 65534:65534 /config/tls/key.pem
chmod 600 /config/tls/key.pem
# A certificate for the server's public name, if the admin put one in /config/tls/public (cert.pem and key.pem):
# fang-api, which runs as nobody, has to read the key. The API's own certificate above stays as it is.
if [[ -f /config/tls/public/key.pem ]]; then
    chown 65534:65534 /config/tls/public/key.pem 2>/dev/null || true
fi

# fang$: a hidden share for the app. devices/ takes sign-in tokens (anyone may add a file, nobody may
# list or remove others'); server.json has the certificate fingerprint (fang-storaged adds the server's
# public and SMB addresses when they're set in the admin page).
mkdir -p /config/fang-share/devices
chmod 755 /config/fang-share
chmod 1733 /config/fang-share/devices
fingerprint=$(openssl x509 -in /config/tls/cert.pem -outform DER | sha256sum | cut -d' ' -f1)
printf '{"fingerprint":"%s","port":%s}\n' "$fingerprint" "${FANG_HTTPS_PORT:-443}" > /config/fang-share/server.json
chmod 644 /config/fang-share/server.json

# Users: Unix accounts in the users group (100), so the share's group-writable files are writable.
while IFS=: read -r name uid; do
    [[ -n $name ]] || continue
    id "$name" >/dev/null 2>&1 || useradd --uid "$uid" --gid 100 --no-create-home --shell /usr/sbin/nologin "$name"
done < /config/users

# FaNG writes only inside its shares. The host folder with them (FANG_SHARE_SOURCE, normally /mnt) is mounted
# read-only (docker-compose.yml), so nothing in this container can create a folder at the top of a pool, where
# Unraid would make it a user share, or anywhere else outside a share. Each share is bound over itself here and
# made writable, with the filesystems below it (ZFS child datasets). A share that is /mnt or a pool's or disk's
# root, is missing, or can't be made writable is left out (fang-storaged then reports it in the admin page).
unescape() { printf '%b' "${1//\\040/ }"; }
make_writable() {
    local path=$1 escaped
    # /mnt, or a folder directly in it: the top of a pool or disk.
    [[ $path == /mnt || $path == /mnt/ || ( $path == /mnt/* && $path != /mnt/*/* ) ]] && return 1
    [[ -d $path ]] || return 1
    mount --rbind "$path" "$path" || return 1
    escaped=${path// /\\040}
    # (Passed through the environment: awk -v would turn the \040 escapes back into spaces.)
    P=$escaped awk '$5 == ENVIRON["P"] || index($5, ENVIRON["P"] "/") == 1 { print $5 }' /proc/self/mountinfo | sort -u |
        while read -r point; do
            mount -o remount,bind,rw "$(unescape "$point")" || exit 1
        done
}
declare -A writable=()
while IFS='|' read -r name path rest; do
    name=$(echo $name) path=$(echo $path)
    [[ -n $name && $name != \#* ]] || continue
    if make_writable "$path"; then
        writable[$name]=1
    else
        echo "share $name ($path): not served (Unraid root, missing, or couldn't be made writable)" >&2
    fi
done < /config/shares.conf
# Home folders (set in the admin page): the folder holding them, made writable as a whole, so new users' folders
# can be made in it. Each user reaches only their own, as [Home] below.
homes_root=$(head -1 /config/homes.conf 2>/dev/null || true)
if [[ -n $homes_root ]] && ! make_writable "$homes_root"; then
    echo "home folders ($homes_root): not served (Unraid root, missing, or couldn't be made writable)" >&2
    homes_root=
fi

# Samba's configuration, from the shares file.
{
    cat <<CONF
[global]
    server role = standalone server
    server string = FaNG
    disable netbios = yes
    smb ports = 445
    server min protocol = SMB3
    map to guest = Never
    load printers = no
    printing = bsd
    printcap name = /dev/null
    passdb backend = tdbsam:/config/samba/private/passdb.tdb
    private dir = /config/samba/private
    state directory = /config/samba/state
    cache directory = /config/samba/cache
    lock directory = /run/samba/lock
    pid directory = /run/samba
    log level = 1
    # A client that vanishes (airplane mode, sleep, a dropped Wi-Fi) never closes its TCP connection, and
    # Linux only probes an idle one after 2 hours. Until then its session keeps its files open, so the
    # client's own retry finds its upload temp busy. Probe after 30 s idle and drop the session after
    # three unanswered probes, about a minute in all.
    socket options = TCP_NODELAY SO_KEEPALIVE TCP_KEEPIDLE=30 TCP_KEEPINTVL=10 TCP_KEEPCNT=3
    # vfs_fang: file I/O as root after Samba's permission check, new items as the host's 99:100 with the
    # share's masks, client chmod/chown ignored. Index numbers stay real (no fruit:zero_file_id): the
    # app matches files by them.
    vfs objects = fang catia fruit streams_xattr
    fang:root io = yes
    fang:uid = 99
    fang:gid = 100
    # Permissions come from FaNG (set in its admin page), as each item's ACL: fang-storaged answers on this
    # socket, from memory. Where no rule gives a user anything, they have no access, whatever the host modes
    # say. The modes, owners and ACLs on disk are never touched.
    fang:acl socket = /run/fang/acl.sock
    # Folders and files a user may not read don't appear in their listings at all.
    hide unreadable = yes
    access based share enum = yes
    fruit:metadata = stream
    fruit:posix_rename = yes
    # Macs send ':' in stream names as U+F022; store a real ':' (as Unraid's Samba does), so Finder tags are
    # user.DosStream.com.apple.metadata:_kMDItemUserTags:\$DATA for every tool.
    fruit:encoding = native
CONF
    cat <<CONF

[fang\$]
    path = /config/fang-share
    browseable = no
    read only = no
    valid users = @users
    # Plain files owned by the user who made them: the owner of a token file says whose it is.
    vfs objects =
    create mask = 0600
CONF
    # (No shares at all is fine: only home folders, or none yet. grep finding nothing mustn't stop the script.)
    { grep -v -E '^\s*(#|$)' /config/shares.conf || true; } | while IFS='|' read -r name path create directory options; do
        name=$(echo $name)
        [[ -n ${writable[$name]:-} ]] || continue
        # Who may see and open this share at all: fang-storaged writes it from the permissions (users with
        # nothing in the share don't see it). Nobody until it has.
        access=/run/fang/shares/$(printf '%s' "$name" | od -An -tx1 | tr -d ' \n').conf
        echo "valid users = +fang-nobody" > "$access"
        cat <<CONF

[$name]
    path = $(echo $path)
    read only = no
    include = $access
    create mask = $(echo $create)
    directory mask = $(echo $directory)
    # FaNG's version store and trash: reached through FaNG, not by browsing the share.
    veto files = /.fang-versions/.fang-trash/
    delete veto files = no
CONF
    done
    if [[ -n $homes_root ]]; then
        homes_access=/run/fang/shares/$(printf '%s' Home | od -An -tx1 | tr -d ' \n').conf
        echo "valid users = +fang-nobody" > "$homes_access"
        cat <<CONF

# Each user's own home folder, named like them (as Unraid's path = .../%U). Inside FaNG it's the share ~user;
# fang:home tells vfs_fang to ask for that share's permissions.
[Home]
    path = $homes_root/%U
    read only = no
    include = $homes_access
    fang:home = yes
    create mask = $(sed -n 's/.*"createMask":"\([0-7]*\)".*/\1/p' /config/homes.json 2>/dev/null | grep . || echo 0664)
    directory mask = $(sed -n 's/.*"directoryMask":"\([0-7]*\)".*/\1/p' /config/homes.json 2>/dev/null | grep . || echo 0775)
    veto files = /.fang-versions/.fang-trash/
    delete veto files = no
CONF
    fi
} > /opt/samba/etc/smb.conf

smbd --foreground --no-process-group --debug-stdout &
# fang-storaged keeps root (fanotify, file handles, xattrs); fang-api runs as nobody.
fang-storaged &
setpriv --reuid=65534 --regid=65534 --clear-groups --inh-caps=-all --bounding-set=-all fang-api &
wait -n
echo "a service stopped; stopping the container"
exit 1
