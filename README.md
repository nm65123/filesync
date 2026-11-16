# filesync

A small, fast, self-hosted file sync and share server written in Rust.
Files only: no calendar, no contacts, no office suite.

**Status: early development. Not ready for production use.**

## What works today

- Upload and download of whole files over HTTP (`PUT` / `GET /files/<path>`)
- Files are stored as plain files on disk, one directory per user
- Atomic writes (temporary file, then rename) with BLAKE3 hashing
- Per-user accounts (Argon2 password hashes) and app tokens, HTTP Basic auth
- File metadata and versions in PostgreSQL
- WebDAV at `/dav/` (per-user root)
- Original modification times are kept when the client sends `X-OC-Mtime`

## Planned

- Bulk import tooling
- Delta transfers (rsync algorithm)
- Change feed for sync clients
- Public share links
- Desktop client with virtual files

## Running

Requires Rust and PostgreSQL.

```sh
export DATABASE_URL=postgres://filesync:PASSWORD@localhost/filesync
cargo run -- adduser alice      # create a user
cargo run -- addtoken alice     # print an app token
cargo run                       # listens on 127.0.0.1:8090
```

Data is stored under `/var/lib/filesync` (override with `FILESYNC_DATA`).

## License

Licensed under either of Apache License 2.0 or MIT license, at your option.
