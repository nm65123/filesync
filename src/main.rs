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
        println!("ascult pe http://{addr} (fara TLS: ruleaza `filesync gencert`)");
        let listener = tokio::net::TcpListener::bind(addr).await?;
        axum::serve(listener, app).await?;
    }
    Ok(())
}
