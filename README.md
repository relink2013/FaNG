<p align="center">
  <img src="docs/images/icon.png" width="140" height="140" alt="FaNG app icon">
</p>

<h1 align="center">FaNG</h1>

<p align="center">
  <strong>Files App Next Generation</strong><br>
  A native iPhone, iPad and Mac app for your own file server, and a Swift + Samba server built for it.
</p>

<p align="center">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-iOS%20%7C%20iPadOS%20%7C%20macOS-blue">
  <img alt="Server" src="https://img.shields.io/badge/server-Docker%20%C2%B7%20Swift%20%C2%B7%20Samba-orange">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
  <img alt="Status" src="https://img.shields.io/badge/status-early-yellow">
</p>

FaNG makes a self-hosted server behave like a real cloud drive in Files and Finder: folders open instantly, thumbnails are already there, files work offline, and a change on one device shows up on the others within seconds. Your files stay plain files on an SMB share that any computer can use.

I built it because every way of using a home server from Apple devices was a compromise. Connecting to SMB in Files is slow and drops out, and self-hosted cloud apps rarely fit into Files and Finder properly. Apple's [File Provider framework](https://developer.apple.com/documentation/fileprovider) makes the real thing possible, so FaNG uses it, all the way.

> [!WARNING]
> Early software. I use it every day with real data, but it has only run on a few setups. Keep backups. 🧪 marks features that are newer and less tested.

## Why FaNG

- **Browsing feels local, even on iPhone.** The server keeps an index of every file, so opening a folder doesn't mean crawling the share over the network.
- **Thumbnails that keep up.** Made on the server as files arrive: photos (HEIC, RAW, AVIF, JPEG XL, PSD…) and video (including ProRes and HDR). Scroll a folder of thousands and they're already there.
- **Full-speed bulk downloads.** Up to 16 files at once on a Mac (4 on iPhone and iPad), large files split across several connections, the next files fetched ahead while an app works through a folder, and SMB encryption reworked to be about 30× faster.
- **Live everywhere.** Changes arrive within seconds. An idle iPhone catches up the moment you open Files.
- **Nothing gets lost.** Versions you can preview and restore, conflicts that keep both edits, and a 🧪 shared 30-day trash.
- **It lives in Files and Finder.** You only open the app to add a server. FaNG can even be Safari's download location, which a server connected directly in Files can't.
- **Plain files, no lock-in.** No storage format of its own, no changes to your files' contents or dates. Windows, Linux and Android connect to FaNG Server over SMB as usual.

<details>
<summary><strong>Everything else it does</strong></summary>

**App:**
- Keep selected files downloaded.
- Edits made offline upload later.
- Transfers resume automatically after a dropped connection.
- **Versions…**, **Resolve Conflict…**, **Copy To…** and **Move To…** directly in the Files and Finder menu (copies and moves run on the server).
- Finder tags and folder icons sync.
- A "Not Synced" list to easily see issues.
- SMB3 with optional encryption.
- 🧪 Delta transfers (only changed blocks).

**Server:**
- Samba with FaNG's own VFS module.
- Stable file IDs through renames and moves.
- Live change tracking with fanotify.
- Versions as space-saving clones where the filesystem supports them (ZFS 2.2+), thinned like Time Machine.
- An isolated thumbnail worker.
- Permissions per folder and user, enforced for every SMB client.
- 🧪 User groups.
- Home folders.
- Admin web page.

The app should also work with any regular SMB server, minus versions, trash, live updates and server thumbnails. In addition, the server should work with any regular SMB client, though no real testing has been done on either of those scenarios yet. Showing versions in Windows Explorer's "Previous Versions" tab is planned.

</details>

### Why Swift on the server?

It's fast, memory-safe and a good fit, and it means the app and server share one language. It's also a small point: "Apple won't let us" gets used to explain a lot of missing features in self-hosted apps, while much of it is possible with public, documented APIs. Building the server in Apple's own language felt fitting.

## Quick start

**Server** (Linux with Docker, kernel 5.17+):

```bash
git clone https://github.com/relink2013/FaNG.git
cd FaNG/Server/docker
cp env.example .env           # set the password, network, IP and folders
docker compose up -d --build  # first build takes 15–30 min
docker exec -it fang fang-user add yourname
```

Open `https://<FANG_IP>/admin`, add a share, and give people access to it (new shares are hidden until you do).

**App** (Xcode 27, devices on iOS / iPadOS / macOS 27):

```bash
cd FaNG/App
scripts/set-identity.sh com.yourname.fang   # your own bundle IDs and signing team
open FaNG.xcodeproj                         # pick a device, Run
```

In the app: **Add Server** → your `FANG_IP`, port 445, user name and password. Then use Files or Finder.

**Good to know**

- FaNG gets its **own IP address** on your network (macvlan; `br0` on Unraid) because it runs a full SMB server on port 445. Other options are under [Setup details](#setup-details).
- **Unraid:** add shares by pool path (`/mnt/<pool>/Photos`). **User shares (`/mnt/user`) aren't supported yet.**
- New files are owned by `99:100` (Unraid's `nobody:users`).
- With a **free Apple ID** the app must be reinstalled from Xcode every 7 days.
- **Mac:** allow FaNG under Privacy & Security → Local Network, or Finder says "No route to host".
- Tested on Unraid with ZFS only.

## Setup details

<details>
<summary><strong>Server settings (.env)</strong></summary>

| Setting | Value |
| --- | --- |
| `FANG_DB_PASSWORD` | A long random password (used only internally) |
| `FANG_LAN_NETWORK` | Docker network on your LAN: `br0` on Unraid, otherwise the one you create below |
| `FANG_IP` | An unused address on your LAN, outside your router's DHCP range |
| `FANG_SHARE_SOURCE` / `FANG_SHARE_TARGET` | The host folder to serve, and where it appears inside FaNG (e.g. `/srv/files` → `/data`). Shares are added by the inside path, e.g. `/data/Photos` |
| `FANG_THUMBNAILS` | Thumbnail folder, ideally on an SSD |
| `FANG_MEMORY`, `FANG_THUMBS_MEMORY`, `FANG_DB_MEMORY`, `FANG_DB_CACHE` | Memory ceilings (defaults 16g / 24g / 12g / 4GB). On 8–16 GB machines try 4g / 4g / 3g / 1GB |

Create the LAN network (not needed on Unraid), with your own subnet, gateway and network card:

```bash
docker network create -d macvlan --subnet=192.168.1.0/24 --gateway=192.168.1.1 -o parent=eth0 fang-lan
```

With macvlan, the host itself can't reach FaNG's address; other devices can.

The admin page uses a self-signed certificate, so your browser will warn. The app pins that certificate when you sign in. The first user you create is the admin; more users can be added in the admin page. Adding or changing a share restarts FaNG's services (about 30 seconds).

</details>

<details>
<summary><strong>Unraid</strong></summary>

- `FANG_LAN_NETWORK=br0`. For several pools, `FANG_SHARE_SOURCE=/mnt` and `FANG_SHARE_TARGET=/mnt`. `/mnt` is mounted read-only and only FaNG's shares are made writable, so it can never create a new top-level user share.
- **User shares (`/mnt/user/...`) aren't supported yet.** FaNG needs the real disks and pools to see changes, and the user-share layer hides them. Add shares by pool path. A share spread over cache and array can't be served as one share today. Support is being worked on: FaNG will read Unraid's share settings and present such shares as one normal folder.
- New files get `99:100` and the share's create and directory masks, like Unraid's own Samba.
- `FANG_ADMIN_URL` and `FANG_ICON_URL` add the WebUI link and icon on the Docker page.

</details>

<details>
<summary><strong>Other Linux hosts (untested)</strong></summary>

- To change the `99:100` owner, edit `fang:uid` / `fang:gid` in `Server/docker/start.sh` and the user in `Server/docker/Dockerfile.thumbs`.
- AppArmor (Ubuntu, for example) can block the bind mounts FaNG uses. If shares show as "not served", `security_opt: ["apparmor:unconfined"]` on the `fang` service is the usual workaround.
- Serve local folders, not network or FUSE mounts: change tracking needs a local filesystem.

</details>

<details>
<summary><strong>Without a separate IP address (untested)</strong></summary>

**Bridge network with custom ports.** FaNG shares the host's address and its SMB server uses another port, which every client then needs (the Port field in the app, `smb://server:1445` elsewhere; some SMB clients can't set a port). In `docker-compose.yml`, replace the `fang` service's `networks:` with:

```yaml
    ports:
      - "1445:445"
      - "8443:8443"
    networks:
      default: {}
      internal: {}
```

Remove the `lan:` network at the bottom and set `FANG_HTTPS_PORT=8443` in `.env` (the API port must match inside and out).

**Host networking.** With the host's own SMB server turned off, FaNG can take ports 445 and 443 directly. The included compose file doesn't support this yet (the database is only reachable on FaNG's internal network).

</details>

<details>
<summary><strong>App</strong></summary>

- Sign in to Xcode first (Settings → Accounts). `set-identity.sh` finds your team from your signing certificate; if it can't, pick the team under Signing & Capabilities for the `FaNG`, `FaNGProvider` and `FaNGActions` targets.
- On iPhone and iPad, turn on Developer Mode and trust your certificate (Settings → General → VPN & Device Management).
- `scripts/deploy.sh` builds and installs on this Mac and every connected iPhone and iPad.
- After reinstalling on iPhone or iPad, force-quit Files if FaNG's menu actions are missing.

</details>

## Limitations

- No TestFlight or App Store build yet (TestFlight is planned, no date).
- Home network only for now; use your own VPN from elsewhere.
- Unraid user shares aren't supported yet, and share changes restart the server.
- No error badges on items yet, no server-wide search.
- Tested on Unraid with ZFS only. Other hosts, Btrfs and XFS are untested but **should** work.

## Roadmap

**Done**

- [x] Files and Finder integration on iPhone, iPad and Mac: browse, offline files, uploads, offline edits, Safari downloads
- [x] Resumable, parallel transfers with read-ahead and fast encryption
- [x] Live updates between devices
- [x] Server: index, stable IDs, live change tracking, permissions, home folders, admin page
- [x] Server-made thumbnails for photos, RAW and video
- [x] Versions, conflict handling, server-side Copy To… and Move To…, synced tags and folder icons
- [x] 🧪 Shared trash
- [x] 🧪 Delta transfers
- [x] 🧪 Groups

**Planned**

- [ ] Unraid user shares, presented as one normal folder
- [ ] Search the whole server from Files and Finder (names, photo details, document text)
- [ ] Share changes without a restart
- [ ] TestFlight
- [ ] Public name and certificate alongside the local address (in progress)
- [ ] Accounts, profile pictures and sign-in with your own OIDC provider
- [ ] A new live web interface with a separate admin area
- [ ] Sharing from Files and Finder, Shared with Me, public links
- [ ] Files over HTTPS and WebDAV where SMB can't reach
- [ ] Linking servers, so friends and family can share between their own FaNG servers
- [ ] Per-device storage settings, error badges, opening large files on a Mac before they finish downloading
- [ ] Windows Previous Versions, PDF and Office thumbnails, quotas
- [ ] Runs without root on any Linux host

**Later**

- [ ] Push notifications
- [ ] App Store
- [ ] Windows, Linux and Android apps

## Repository

- `App/`: the Xcode project. `FaNG` (app), `FaNGProvider` (File Provider extension), `FaNGActions` (menu sheets), `FaNGKit` (shared code), `Vendor/AMSMB2` (SMB library, changes in [FANG-PATCHES.md](App/Vendor/AMSMB2/FANG-PATCHES.md)).
- `Server/`: the Swift package (`fang-api`, `fang-storaged`, `fang-thumbs`), the Samba module (`samba/vfs_fang`) and `docker/`.

Tests: `swift test --package-path App/FaNGKit` and `swift test --package-path Server`.

## License

[MIT](LICENSE). Included and bundled projects keep their own licenses: [AMSMB2](https://github.com/amosavian/AMSMB2) and [libsmb2](https://github.com/sahlberg/libsmb2) (LGPL 2.1), [Samba](https://www.samba.org) (GPL 3.0, built into the server image), plus Hummingbird, PostgresNIO, SwiftNIO SSL, Swift Crypto, PostgreSQL, pgvector, Valkey, libvips, FFmpeg and ExifTool.

FaNG isn't affiliated with Apple.
