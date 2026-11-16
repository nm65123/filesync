# filesync

A small, fast, self-hosted file sync and share server written in Rust.
Files only: no calendar, no contacts, no office suite.

**Status: early development. Not ready for production use.**

- Files are stored as plain files on disk, one directory per user.
- Access over HTTPS: WebDAV at `/dav/` and a simple `PUT`/`GET` API at `/files/`.
- Users exist only in the database (no system accounts), each with an
  optional quota.
- Built-in HTTPS with a self-signed certificate. It works with a bare IP
  address; no domain name is needed.
- Original file dates are kept when the client sends them (rclone does).
- A sync client (`filesync-client`) keeps a local directory identical with
  the server, in both directions.
- Public share links for a file or a directory, optionally with a password
  and an expiry date.
- Every file and directory is indexed in PostgreSQL (size, BLAKE3 hash, date,
  version). A change feed tells sync clients what changed since their last
  visit.

Contents: [1. Install the server](#1-install-the-server) ·
[2. Manage users](#2-manage-users) ·
[3. Connect a computer](#3-connect-a-computer) ·
[4. Sync client](#4-sync-client) ·
[5. Update](#5-update) ·
[6. Settings](#6-settings) ·
[7. Known limitations](#7-known-limitations)

---

## 1. Install the server

For Debian 12+ or Ubuntu 22.04+. Run everything as `root`. In the examples
the server's address is `192.168.0.48`; use your own.

### 1.1 Packages and Rust

```sh
apt update
apt install -y build-essential pkg-config git curl openssl postgresql
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
. ~/.cargo/env
```

### 1.2 Build and install the program

```sh
git clone https://github.com/nm65123/filesync.git
cd filesync
cargo build --release
install -m 755 target/release/filesync /usr/local/bin/filesync
```

The first build takes a few minutes.

### 1.3 Database

```sh
P=$(openssl rand -hex 16)
cd /tmp
runuser -u postgres -- psql -c "CREATE USER filesync PASSWORD '$P';" \
                            -c "CREATE DATABASE filesync OWNER filesync;"
```

Keep the terminal open: the next step uses `$P`. The tables are created
automatically when the server first starts.

### 1.4 Service account, data directory, settings

```sh
useradd --system --home-dir /var/lib/filesync --shell /usr/sbin/nologin filesync
install -d -o filesync -g filesync -m 750 /var/lib/filesync
printf '%s\n' \
  "DATABASE_URL=postgres://filesync:$P@localhost/filesync" \
  "FILESYNC_DATA=/var/lib/filesync" \
  "FILESYNC_LISTEN=0.0.0.0:8443" > /etc/filesync.env
chmod 600 /etc/filesync.env
```

### 1.5 Certificate

List every address and name that computers will use to reach the server:

```sh
runuser -u filesync -- env FILESYNC_DATA=/var/lib/filesync \
    filesync gencert 192.168.0.48
```

For example `filesync gencert 192.168.0.48 files.example.org`.

The command creates two things: a small certificate authority of your own,
and the server's certificate, signed by it. Computers install the
authority's certificate once (step 3.1). The command prints its **SHA-256
fingerprint**. Write it down: you need it in step 3.1.

The server's certificate is valid for 825 days. To renew it, or to add a
name or an address, run the same command again and restart the service. The
authority stays the same, so the computers do not have to do anything.
(`--force` replaces the authority too; then every computer has to repeat
step 3.1.)

### 1.6 Start it as a service

```sh
cat > /etc/systemd/system/filesync.service <<'UNIT'
[Unit]
Description=filesync server
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=filesync
Group=filesync
EnvironmentFile=/etc/filesync.env
ExecStart=/usr/local/bin/filesync
Restart=on-failure
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now filesync
systemctl status filesync --no-pager
```

### 1.7 Check

```sh
curl -k https://192.168.0.48:8443/health
```

It must answer `ok`. If not, `journalctl -u filesync -n 20` shows why.

---

## 2. Manage users

Commands need the settings file, so load it once per terminal:

```sh
set -a; . /etc/filesync.env; set +a
```

Then:

```sh
filesync adduser alice            # asks for a password (8+ characters)
filesync addtoken alice           # prints an app token for clients
filesync users                    # list: e-mail, group, usage, quota...
```

User names are unique, cannot be changed later, and may contain lowercase
letters, digits, `.`, `-` and `_`.

| Command                              | What it does                         |
|--------------------------------------|--------------------------------------|
| `filesync passwd alice`              | change the password                  |
| `filesync quota alice 10G`           | quota: `500M`, `10G`, `1T`, `none`   |
| `filesync email alice a@example.org` | e-mail address (`none` to clear)     |
| `filesync group alice office`        | group (`none` to clear)              |
| `filesync admin alice on`            | administrator flag (`off` to remove) |
| `filesync disable alice`             | block the account (`enable` undoes)  |
| `filesync tokens alice`              | list the account's tokens            |
| `filesync deltoken alice ID`         | delete one token (`all` for all)     |
| `filesync reindex [alice]`           | rebuild the index from the disk      |
| `filesync share alice docs/a.pdf`    | create a public link (see 3.6)       |
| `filesync shares [alice]`            | list the links                       |
| `filesync unshare CODE`              | delete a link                        |
| `filesync help`                      | list all commands                    |

Clients log in with the user name and either the password or, better, an
app token: a token can be deleted without changing the password.

When an upload would exceed the quota the server refuses it with
`507 Insufficient Storage` and a message such as
`Cota depasita: fisierul are 4.9 KiB, spatiu disponibil 524 B.`

---

## 3. Connect a computer

### 3.1 Trust the certificate (once per computer)

The server's certificate is signed by its own authority, which other
computers do not know, so each one has to be told to trust it. Download the
authority's certificate, check that its fingerprint is the one printed in
step 1.5, then install it. **If the fingerprints differ, stop:** the file is
not your server's certificate.

**Windows** (PowerShell opened as administrator):

```powershell
curl.exe -k https://192.168.0.48:8443/cert.crt -o filesync.crt
$c = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path filesync.crt).Path)
[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($c.RawData)) -replace '-',':'
certutil -addstore -f Root filesync.crt
```

The third line prints the fingerprint. Run the fourth only if it matches.

**Linux** (Debian/Ubuntu):

```sh
curl -k https://192.168.0.48:8443/cert.crt -o filesync.crt
openssl x509 -in filesync.crt -noout -fingerprint -sha256
cp filesync.crt /usr/local/share/ca-certificates/ && update-ca-certificates
```

**macOS**:

```sh
curl -k https://192.168.0.48:8443/cert.crt -o filesync.crt
openssl x509 -in filesync.crt -noout -fingerprint -sha256
sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain filesync.crt
```

To see the fingerprint again on the server:

```sh
openssl x509 -in /var/lib/filesync/tls/ca.pem -noout -fingerprint -sha256
```

### 3.2 Copy files with rclone (keeps the original dates)

```sh
rclone config create filesync webdav url=https://192.168.0.48:8443/dav \
    vendor=owncloud user=alice pass=TOKEN --obscure
rclone copy ~/Documents filesync:Documents -v
```

If the certificate is not installed system-wide, add `--ca-cert filesync.crt`
to the rclone commands.

### 3.3 Mount as a network drive

The WebDAV address is `https://192.168.0.48:8443/dav/`, with the user name
and a token as password. Note that Windows Explorer and Finder do not send
the original file dates, so files copied this way get the upload time. Use
rclone when dates matter.

### 3.4 Plain HTTP API

```sh
curl -u alice:TOKEN -T report.pdf https://192.168.0.48:8443/files/docs/report.pdf
curl -u alice:TOKEN https://192.168.0.48:8443/files/docs/report.pdf -o report.pdf
curl -u alice:TOKEN -X DELETE https://192.168.0.48:8443/files/docs/report.pdf
```

Add `-H "X-OC-Mtime: <unix seconds>"` on upload to set the file's date.
`DELETE` also removes a directory with everything in it.

Sync clients can make a write conditional with `X-Filesync-If-Version: N`:
the server answers `412` when the file's current version is not `N` (`0`
means "must not exist yet"). `PUT /api/dirs/<path>` creates a directory.

### 3.5 Change feed (for sync clients)

Every change gets a sequence number. A client remembers the last number it
has seen (its cursor) and asks for everything after it:

```sh
curl -u alice:TOKEN "https://192.168.0.48:8443/api/changes?since=0"
```

```json
{
  "cursor": 12,
  "more": false,
  "entries": [
    { "path": "docs", "dir": true, "size": 0, "hash": "", "mtime": 0,
      "version": 1, "seq": 11, "deleted": false },
    { "path": "docs/report.pdf", "dir": false, "size": 48213,
      "hash": "c450580a...", "mtime": 1600000000,
      "version": 1, "seq": 12, "deleted": false }
  ]
}
```

- `since=0` returns everything that exists. Send the returned `cursor` as
  `since` next time to get only what changed in between.
- `more: true` means there is more: ask again with the new cursor. `limit`
  sets the page size (default 1000, maximum 10000).
- A deleted file or directory appears with `"deleted": true`.
- `hash` is the BLAKE3 hash of the content, `mtime` the file date in Unix
  seconds, `version` counts the changes to that path.

### 3.6 Share links

A link gives anyone who has it access to one file or one directory, without
an account. On the server:

```sh
filesync share alice docs/report.pdf
filesync share alice photos --days 7 --password     # asks for the password
```

The command prints the address, for example
`https://192.168.0.48:8443/s/7b4ec5e01cd02facd44ef411ca29eb37`.

- A link to a file downloads it. A link to a directory shows a page with its
  content; everything below that directory is reachable, nothing above it.
- With `--password`, the browser asks for the password (the user name field
  can be left empty or filled with anything).
- With `--days N`, the link stops working after N days.
- `filesync shares` lists the links and how often each was used;
  `filesync unshare CODE` deletes one. Disabling a user disables the links.
- If the shared file or directory is moved, renamed or deleted, the link
  stops working.

Users can manage their own links through the API:

```sh
curl -u alice:TOKEN -H "Content-Type: application/json" \
     -d '{"path":"photos","days":7,"password":"secret"}' \
     https://192.168.0.48:8443/api/shares           # create; returns the url
curl -u alice:TOKEN https://192.168.0.48:8443/api/shares                # list
curl -u alice:TOKEN -X DELETE https://192.168.0.48:8443/api/shares/CODE  # delete
```

If people outside reach the server under another address than the one it
listens on (a domain name, a forwarded port), set `FILESYNC_URL` to that
address so the links are printed correctly.

---

## 4. Sync client

`filesync-client` keeps one local directory identical with a user's space on
the server. Files stay real files on both sides.

### 4.1 Build

On Linux, in the directory of the source code:

```sh
cargo build --release -p filesync-client
install -m 755 target/release/filesync-client /usr/local/bin/filesync-client
```

On Windows, install Rust from <https://rustup.rs> (the installer also offers
the Microsoft C++ build tools it needs) and Git from <https://git-scm.com>,
then in PowerShell:

```powershell
git clone https://github.com/nm65123/filesync.git
cd filesync
cargo build --release -p filesync-client
```

The program is `target\release\filesync-client.exe`; copy it wherever you
like. The Windows build has not been tested yet.

### 4.2 Before you connect: certificate and token

The client needs two things from the server. Prepare them first.

**The certificate file** (only when the server uses its own certificate
authority, as in step 1.5). On the computer that will run the client:

```sh
curl -k https://192.168.0.48:8443/cert.crt -o filesync.crt
openssl x509 -in filesync.crt -noout -fingerprint -sha256
```

On Windows use `curl.exe` and the fingerprint lines from step 3.1. The
fingerprint must be the one printed by `gencert` on the server. The client
uses this file; it does not look at the certificates installed in the
operating system, so this step is needed even if you did step 3.1.

**An app token**, one for each computer. On the server:

```sh
set -a; . /etc/filesync.env; set +a
filesync adduser alice        # only if the account does not exist yet
filesync addtoken alice
```

`addtoken` prints the token, a line of 64 letters and digits, exactly once:
copy it now, it cannot be shown again. It also prints the token's id (8
characters). The token replaces the password for this computer. When a
computer is lost or retired, delete only its token and the others keep
working:

```sh
filesync tokens alice         # ids and creation dates
filesync deltoken alice ID
```

### 4.3 Connect

```sh
filesync-client setup --url https://192.168.0.48:8443 --user alice \
    --dir ~/Files --ca-cert filesync.crt
```

On Windows:

```powershell
.\filesync-client.exe setup --url https://192.168.0.48:8443 --user alice `
    --dir $HOME\Files --ca-cert $HOME\filesync.crt
```

It asks for the token (paste it and press Enter), checks the connection and
remembers everything. Start with a new, empty directory, or with one whose
content you want merged with the server. Leave `--ca-cert` out when the
server has a certificate from a public authority. `--token-file FILE` reads
the token from a file instead of asking.

To replace a token later, run `setup` again with the same directory; the
sync state is kept.

### 4.4 Run

```sh
filesync-client once         # one sync, then exit
filesync-client run          # keeps syncing every 10 seconds; Ctrl+C stops
filesync-client status
```

`--interval N` changes the pause. `--profile NAME` (on every command) lets
one computer sync several directories or accounts. Only one client can run
per profile; a second one refuses to start.

**In the background.** On Windows:

```powershell
.\filesync-client.exe autostart on      # autostart off  undoes it
```

The client then starts by itself at every sign-in, without a window, and
writes what it does to `%APPDATA%\filesync-client\default\client.log`. Do
not move the program afterwards (or run `autostart on` again from its new
place).

On Linux, as a systemd user service:

```sh
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/filesync-client.service <<'UNIT'
[Unit]
Description=filesync client

[Service]
ExecStart=/usr/local/bin/filesync-client run
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now filesync-client
journalctl --user -u filesync-client -n 20
```

Anywhere, `--log FILE` writes the messages to a file, with date and time
(UTC), instead of the screen.

### 4.5 What it does

- New and changed files travel in both directions, with their original
  dates. Every download is verified against the server's hash.
- A file changed on both sides since the last sync is a **conflict**:
  nothing is lost. The server's version keeps the name, and the local one is
  kept as `name (conflict 2026-11-16 computer).ext` and uploaded too.
- Deletions travel in both directions. A file changed on one side wins over
  its deletion on the other.
- If more than 50 entries and more than half of everything would be deleted
  from the server in one go, the client stops and asks you to confirm with
  `--allow-mass-delete`. If the local directory is missing (a disk that is
  not mounted), it does nothing.
- Temporary and system files are not synced: `~$*`, `.~lock.*`, `*.tmp`,
  `*.part`, `*.crdownload`, `Thumbs.db`, `desktop.ini`, `.DS_Store`.
- A file that is still being written is left for the next round.

Settings and the sync state are kept in `~/.config/filesync-client/` (Linux,
macOS) or `%APPDATA%\filesync-client\` (Windows). The token is stored there
in plain text, readable only by your user.

---

## 5. Update

```sh
cd filesync
git pull
cargo build --release
install -m 755 target/release/filesync /usr/local/bin/filesync
systemctl restart filesync
```

Database changes are applied automatically at start. Rebuild the client the
same way (step 4.1) on the computers that use it.

---

## 6. Settings

Set in `/etc/filesync.env`; restart the service after a change.

| Variable                 | Default                       | Meaning                              |
|--------------------------|-------------------------------|--------------------------------------|
| `DATABASE_URL`           | (required)                    | PostgreSQL connection                |
| `FILESYNC_DATA`          | `/var/lib/filesync`           | files, temporary files, certificate  |
| `FILESYNC_LISTEN`        | `127.0.0.1:8090`              | address and port to listen on        |
| `FILESYNC_TLS_CERT`      | `$FILESYNC_DATA/tls/cert.pem` | certificate (PEM)                    |
| `FILESYNC_TLS_KEY`       | `$FILESYNC_DATA/tls/key.pem`  | private key (PEM)                    |
| `FILESYNC_INSECURE_HTTP` | unset                         | `1` allows plain HTTP on the network |
| `FILESYNC_URL`           | unset                         | public address, used in share links  |

If the certificate and key exist, the server speaks HTTPS. Without them it
speaks plain HTTP, and only on `127.0.0.1`, because passwords would otherwise
travel unencrypted. Set `FILESYNC_INSECURE_HTTP=1` only when a reverse proxy
in front of the server does the HTTPS.

To use a certificate from a public authority (for example Let's Encrypt),
point `FILESYNC_TLS_CERT` and `FILESYNC_TLS_KEY` at its files. Clients then
need no extra step.

Where things are:

| Path                           | Content                         |
|--------------------------------|---------------------------------|
| `/var/lib/filesync/files/NAME` | the files of user `NAME`        |
| `/var/lib/filesync/tls`        | certificate and private key     |
| `/etc/filesync.env`            | settings, database password     |
| PostgreSQL database `filesync` | users, tokens, links, file index |

The index can always be rebuilt from the files with `filesync reindex`.

Back up the data directory and the database together.

---

## 7. Known limitations

- The disk is the source of truth and the index follows it. Files put
  directly into the data directory (not through the server) are not seen
  until you run `filesync reindex`. Run it also after a crash or a restore.
- A file uploaded through WebDAV is read once more after the upload, to
  compute its hash.
- WebDAV `COPY` is not checked against the quota.
- Sync client: it finds local changes by scanning the directory at every
  round (no file-system notifications yet); files are real files (no virtual
  files yet); only one client per profile may run at a time; names that
  differ only in letter case are not handled on Windows and macOS.
- Share links: wrong passwords are not rate-limited, and a shared directory
  cannot be downloaded as a single archive.
- The group and administrator flag are stored but not used yet.
- Server messages are in Romanian.

Planned: virtual files in the client (Windows Cloud Files, FUSE), delta
transfers (rsync algorithm).

## License

Licensed under either of Apache License 2.0 or MIT license, at your option.
