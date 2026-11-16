#!/bin/bash
# filesync, pasul 6: README pas cu pas (instalare pe orice server), refuz HTTP necriptat pe retea.
# Ruleaza pe serverul filesync:  bash filesync-pas6.sh   (sau lipeste tot continutul in terminal)
cd ~/filesync || exit 1
source ~/.cargo/env 2>/dev/null
cat > src/main.rs <<'FILESYNC_EOF'
mod admin;
mod http;
mod util;

use dav_server::{fakels::FakeLs, DavHandler};
use sqlx::postgres::PgPoolOptions;
use std::net::SocketAddr;
use std::path::PathBuf;

const SCHEMA: [&str; 8] = [
    "CREATE TABLE IF NOT EXISTS users (
        id       SERIAL PRIMARY KEY,
        name     TEXT NOT NULL UNIQUE,
        password TEXT NOT NULL
    )",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS email TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS grp TEXT",
    // NULL inseamna cota nelimitata
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS quota BIGINT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS admin BOOLEAN NOT NULL DEFAULT false",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT true",
    "CREATE TABLE IF NOT EXISTS tokens (
        hash    TEXT PRIMARY KEY,
        user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created TIMESTAMPTZ NOT NULL DEFAULT now()
    )",
    "CREATE TABLE IF NOT EXISTS files (
        owner    INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        path     TEXT NOT NULL,
        size     BIGINT NOT NULL,
        hash     TEXT NOT NULL,
        version  BIGINT NOT NULL DEFAULT 1,
        modified TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (owner, path)
    )",
];

#[tokio::main]
async fn main() {
    if let Err(e) = start().await {
        eprintln!("eroare: {e}");
        std::process::exit(1);
    }
}

async fn start() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let data = PathBuf::from(
        std::env::var("FILESYNC_DATA").unwrap_or_else(|_| "/var/lib/filesync".into()),
    );
    if admin::local(&data, &args)? {
        return Ok(());
    }

    let url = std::env::var("DATABASE_URL").map_err(|_| "lipseste variabila DATABASE_URL")?;
    let pool = PgPoolOptions::new().max_connections(5).connect(&url).await?;
    for sql in SCHEMA {
        sqlx::query(sql).execute(&pool).await?;
    }
    if admin::run(&pool, &data, &args).await? {
        return Ok(());
    }

    tokio::fs::create_dir_all(data.join("files")).await?;
    let tmp = data.join("tmp");
    let _ = tokio::fs::remove_dir_all(&tmp).await; // resturi de la transferuri intrerupte
    tokio::fs::create_dir_all(&tmp).await?;

    // TLS: din variabile, sau certificatul creat cu `filesync gencert`.
    let cert = std::env::var("FILESYNC_TLS_CERT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| data.join("tls/cert.pem"));
    let key = std::env::var("FILESYNC_TLS_KEY")
        .map(PathBuf::from)
        .unwrap_or_else(|_| data.join("tls/key.pem"));
    let tls = cert.exists() && key.exists();

    let dav = DavHandler::builder()
        .locksystem(FakeLs::new())
        .strip_prefix("/dav")
        .build_handler();
    let app = http::router(http::App {
        pool,
        data,
        dav,
        cert: tls.then(|| cert.clone()),
    });

    let addr: SocketAddr = std::env::var("FILESYNC_LISTEN")
        .unwrap_or_else(|_| "127.0.0.1:8090".into())
        .parse()
        .map_err(|_| "FILESYNC_LISTEN trebuie sa fie de forma 192.168.0.48:8443")?;

    if tls {
        let config = axum_server::tls_rustls::RustlsConfig::from_pem_file(&cert, &key).await?;
        println!("ascult pe https://{addr}");
        axum_server::bind_rustls(addr, config)
            .serve(app.into_make_service())
            .await?;
    } else {
        // Fara TLS parolele ar circula necriptat, deci acceptam doar adresa locala,
        // sau un proxy care face el HTTPS (FILESYNC_INSECURE_HTTP=1).
        let allowed = std::env::var("FILESYNC_INSECURE_HTTP").is_ok_and(|v| v == "1");
        if !addr.ip().is_loopback() && !allowed {
            return Err(format!(
                "nu exista certificat TLS, iar {addr} nu este o adresa locala. \
                 Ruleaza `filesync gencert <ip sau nume>` sau, daca in fata este un proxy \
                 care face HTTPS, seteaza FILESYNC_INSECURE_HTTP=1."
            )
            .into());
        }
        println!("ascult pe http://{addr} (fara TLS)");
        let listener = tokio::net::TcpListener::bind(addr).await?;
        axum::serve(listener, app).await?;
    }
    Ok(())
}
FILESYNC_EOF
cat > README.md <<'FILESYNC_EOF'
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

Contents: [1. Install the server](#1-install-the-server) ·
[2. Manage users](#2-manage-users) ·
[3. Connect a computer](#3-connect-a-computer) ·
[4. Update](#4-update) ·
[5. Settings](#5-settings) ·
[6. Known limitations](#6-known-limitations)

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

For example `filesync gencert 192.168.0.48 files.example.org`. The command
prints the certificate's **SHA-256 fingerprint**. Write it down: you need it
in step 3.1. The certificate is valid for 825 days; run the same command
again to renew it, then restart the service.

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
| `filesync help`                      | list all commands                    |

Clients log in with the user name and either the password or, better, an
app token: a token can be deleted without changing the password.

When an upload would exceed the quota the server refuses it with
`507 Insufficient Storage` and a message such as
`Cota depasita: fisierul are 4.9 KiB, spatiu disponibil 524 B.`

---

## 3. Connect a computer

### 3.1 Trust the certificate (once per computer)

A self-signed certificate is unknown to other computers, so each one has to
be told to trust it. Download it, check that its fingerprint is the one
printed in step 1.5, then install it. **If the fingerprints differ, stop:**
the file is not your server's certificate.

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
openssl x509 -in /var/lib/filesync/tls/cert.pem -noout -fingerprint -sha256
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
```

Add `-H "X-OC-Mtime: <unix seconds>"` on upload to set the file's date.

---

## 4. Update

```sh
cd filesync
git pull
cargo build --release
install -m 755 target/release/filesync /usr/local/bin/filesync
systemctl restart filesync
```

Database changes are applied automatically at start.

---

## 5. Settings

Set in `/etc/filesync.env`; restart the service after a change.

| Variable                 | Default                       | Meaning                              |
|--------------------------|-------------------------------|--------------------------------------|
| `DATABASE_URL`           | (required)                    | PostgreSQL connection                |
| `FILESYNC_DATA`          | `/var/lib/filesync`           | files, temporary files, certificate  |
| `FILESYNC_LISTEN`        | `127.0.0.1:8090`              | address and port to listen on        |
| `FILESYNC_TLS_CERT`      | `$FILESYNC_DATA/tls/cert.pem` | certificate (PEM)                    |
| `FILESYNC_TLS_KEY`       | `$FILESYNC_DATA/tls/key.pem`  | private key (PEM)                    |
| `FILESYNC_INSECURE_HTTP` | unset                         | `1` allows plain HTTP on the network |

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
| PostgreSQL database `filesync` | users, tokens, file index       |

Back up the data directory and the database together.

---

## 6. Known limitations

- Files written through WebDAV are not yet recorded in the database index.
- Quota usage is computed by scanning the user's directory, which is slow
  with very many files.
- WebDAV `COPY` is not checked against the quota.
- The group and administrator flag are stored but not used yet.
- Server messages are in Romanian.

Planned: file index and change feed for sync clients, delta transfers
(rsync algorithm), public share links, desktop client with virtual files.

## License

Licensed under either of Apache License 2.0 or MIT license, at your option.
FILESYNC_EOF
cargo build && echo "=== compilat cu succes ==="
