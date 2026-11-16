# filesync

A small, fast, self-hosted file sync and share server written in Rust.
Files only: no calendar, no contacts, no office suite.

**Status: early development. Not ready for production use.**

## What works today

- Files are stored as plain files on disk, one directory per user
- Upload and download over HTTPS (`PUT` / `GET /files/<path>`) and WebDAV (`/dav/`)
- Atomic writes (temporary file, then rename) with BLAKE3 hashing
- Original modification times are kept when the client sends `X-OC-Mtime`
  (rclone and the ownCloud/Nextcloud clients do)
- Virtual users stored in PostgreSQL (no system accounts): Argon2 password
  hashes, app tokens, e-mail, group, administrator flag, enable/disable
- Per-user quota, checked before an upload is accepted
- Built-in HTTPS with a self-signed certificate, also for a bare IP address

## Planned

- File index and change feed for sync clients
- Delta transfers (rsync algorithm)
- Public share links
- Desktop client with virtual files

## Install

Requires Rust, PostgreSQL and `openssl` (only for generating the certificate).

    sudo -u postgres psql -c "CREATE USER filesync PASSWORD 'CHANGE_ME';" \
                          -c "CREATE DATABASE filesync OWNER filesync;"
    export DATABASE_URL=postgres://filesync:CHANGE_ME@localhost/filesync
    cargo build --release

The tables are created automatically on first start.

## Configuration

| Variable            | Default                          | Meaning                    |
|---------------------|----------------------------------|----------------------------|
| `DATABASE_URL`      | (required)                       | PostgreSQL connection      |
| `FILESYNC_DATA`     | `/var/lib/filesync`              | files, temp files, TLS     |
| `FILESYNC_LISTEN`   | `127.0.0.1:8090`                 | address and port           |
| `FILESYNC_TLS_CERT` | `$FILESYNC_DATA/tls/cert.pem`    | certificate (PEM)          |
| `FILESYNC_TLS_KEY`  | `$FILESYNC_DATA/tls/key.pem`     | private key (PEM)          |

If the certificate and key files exist, the server speaks HTTPS; otherwise
plain HTTP. Never expose plain HTTP to a network: passwords would travel
unencrypted.

## HTTPS with a self-signed certificate

No domain name is needed. Generate a certificate for the IP address and/or
names clients will use to reach the server:

    filesync gencert 192.168.0.48 files.example.org
    FILESYNC_LISTEN=192.168.0.48:8443 filesync

The certificate is valid for 825 days; run `gencert` again to renew it. The
command prints the SHA-256 fingerprint.

Clients do not know a self-signed certificate, so each client has to be told
to trust it once. Download it from the server:

    curl -k https://192.168.0.48:8443/cert.crt -o filesync.crt
    openssl x509 -in filesync.crt -noout -fingerprint -sha256

Compare the fingerprint with the one printed by `gencert` on the server. If
they match, the file is the real certificate. Then:

- **curl**: `curl --cacert filesync.crt https://192.168.0.48:8443/health`
- **rclone**: add `--ca-cert filesync.crt` to the commands
- **Windows**: `certutil -addstore -f Root filesync.crt` in an administrator
  prompt (or double-click the file and install it into "Trusted Root
  Certification Authorities")
- **Debian/Ubuntu**: `cp filesync.crt /usr/local/share/ca-certificates/ &&
  update-ca-certificates`
- **macOS**: open the file in Keychain Access and set it to "Always Trust"

To use a certificate from a public authority instead (for example Let's
Encrypt), point `FILESYNC_TLS_CERT` and `FILESYNC_TLS_KEY` at its files, or
put a reverse proxy in front of the server.

## Users

Users exist only in the database. Names are unique, cannot be changed later
and may contain lowercase letters, digits, `.`, `-` and `_`.

    filesync adduser alice            # asks for a password (8+ characters)
    filesync passwd alice
    filesync users                    # list: e-mail, group, usage, quota...
    filesync quota alice 10G          # or 500M, 1T, none (unlimited)
    filesync email alice alice@example.org
    filesync group alice office
    filesync admin alice on           # stored; no admin interface yet
    filesync disable alice            # enable alice to undo
    filesync addtoken alice           # prints an app token
    filesync tokens alice
    filesync deltoken alice <id|all>

Clients authenticate with HTTP Basic, using the account password or, better,
an app token.

When an upload would exceed the quota, the server answers
`507 Insufficient Storage` with a message that says how large the file is and
how much space is left.

## Connecting clients

WebDAV address: `https://SERVER:8443/dav/`

rclone, which keeps the original modification times:

    rclone config create filesync webdav url=https://192.168.0.48:8443/dav \
        vendor=owncloud user=alice pass=TOKEN --obscure
    rclone copy ~/Documents filesync:Documents --ca-cert filesync.crt -v

## Known limitations

- Files written through WebDAV are not yet recorded in the database index
- Quota usage is computed by scanning the user's directory
- WebDAV `COPY` is not checked against the quota
- Windows Explorer and Finder do not send `X-OC-Mtime`, so files copied with
  them get the upload time

## License

Licensed under either of Apache License 2.0 or MIT license, at your option.
