use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use base64::Engine;
use futures_util::StreamExt;
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::io::Read;
use std::path::{Component, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::io::AsyncWriteExt;

#[derive(Clone)]
struct App {
    pool: PgPool,
    data: PathBuf,
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = std::env::var("DATABASE_URL")?;
    let data = PathBuf::from(
        std::env::var("FILESYNC_DATA").unwrap_or_else(|_| "/var/lib/filesync".into()),
    );
    let pool = PgPoolOptions::new().max_connections(5).connect(&url).await?;

    for sql in [
        "CREATE TABLE IF NOT EXISTS users (
            id       SERIAL PRIMARY KEY,
            name     TEXT NOT NULL UNIQUE,
            password TEXT NOT NULL
        )",
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
    ] {
        sqlx::query(sql).execute(&pool).await?;
    }

    // Comenzi de administrare: adduser <nume>, addtoken <nume>
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("adduser") => {
            let name = args.get(2).ok_or("lipseste numele")?;
            if !valid_name(name) {
                return Err("nume invalid: doar litere mici, cifre, punct, - si _".into());
            }
            eprint!("parola pentru {name}: ");
            let mut pw = String::new();
            std::io::stdin().read_line(&mut pw)?;
            let salt = SaltString::generate(&mut OsRng);
            let hash = Argon2::default()
                .hash_password(pw.trim_end().as_bytes(), &salt)
                .map_err(|e| e.to_string())?
                .to_string();
            sqlx::query(
                "INSERT INTO users (name, password) VALUES ($1, $2)
                 ON CONFLICT (name) DO UPDATE SET password = $2",
            )
            .bind(name)
            .bind(&hash)
            .execute(&pool)
            .await?;
            eprintln!("utilizator salvat: {name}");
            return Ok(());
        }
        Some("addtoken") => {
            let name = args.get(2).ok_or("lipseste numele")?;
            let token = random_hex()?;
            let done = sqlx::query(
                "INSERT INTO tokens (hash, user_id) SELECT $1, id FROM users WHERE name = $2",
            )
            .bind(blake3::hash(token.as_bytes()).to_hex().to_string())
            .bind(name)
            .execute(&pool)
            .await?;
            if done.rows_affected() == 0 {
                return Err("utilizator inexistent".into());
            }
            println!("{token}");
            return Ok(());
        }
        _ => {}
    }

    tokio::fs::create_dir_all(data.join("files")).await?;
    let tmp = data.join("tmp");
    let _ = tokio::fs::remove_dir_all(&tmp).await; // resturi de la transferuri intrerupte
    tokio::fs::create_dir_all(&tmp).await?;

    let app = Router::new()
        .route("/health", get(health))
        .route("/files/{*path}", get(download).put(upload))
        .with_state(App { pool, data });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:8090").await?;
    println!("ascult pe 127.0.0.1:8090");
    axum::serve(listener, app).await?;
    Ok(())
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '-' | '_'))
}

fn random_hex() -> std::io::Result<String> {
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

// Accepta doar cai relative simple: fara "..", fara "/" la inceput.
fn safe(path: &str) -> Option<PathBuf> {
    let p = std::path::Path::new(path);
    if path.is_empty() || !p.components().all(|c| matches!(c, Component::Normal(_))) {
        return None;
    }
    Some(p.components().collect())
}

fn bad() -> Response {
    StatusCode::BAD_REQUEST.into_response()
}

fn internal<E: std::fmt::Display>(e: E) -> Response {
    eprintln!("eroare: {e}");
    StatusCode::INTERNAL_SERVER_ERROR.into_response()
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        [(header::WWW_AUTHENTICATE, "Basic realm=\"filesync\"")],
    )
        .into_response()
}

// Intoarce (id, nume) daca cererea are un token sau o parola valida.
async fn auth(app: &App, headers: &HeaderMap) -> Result<(i32, String), Response> {
    let value = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Basic "))
        .ok_or_else(unauthorized)?;
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(value)
        .map_err(|_| unauthorized())?;
    let decoded = String::from_utf8(decoded).map_err(|_| unauthorized())?;
    let (name, secret) = decoded.split_once(':').ok_or_else(unauthorized)?;

    let user = sqlx::query_as::<_, (i32, String)>("SELECT id, password FROM users WHERE name = $1")
        .bind(name)
        .fetch_optional(&app.pool)
        .await
        .map_err(internal)?
        .ok_or_else(unauthorized)?;

    // Intai tokenul (rapid), apoi parola contului (Argon2, lent intentionat).
    let token_hash = blake3::hash(secret.as_bytes()).to_hex().to_string();
    let by_token = sqlx::query_as::<_, (i32,)>(
        "SELECT user_id FROM tokens WHERE hash = $1 AND user_id = $2",
    )
    .bind(&token_hash)
    .bind(user.0)
    .fetch_optional(&app.pool)
    .await
    .map_err(internal)?;
    if by_token.is_some() {
        return Ok((user.0, name.to_string()));
    }

    let parsed = PasswordHash::new(&user.1).map_err(internal)?;
    Argon2::default()
        .verify_password(secret.as_bytes(), &parsed)
        .map_err(|_| unauthorized())?;
    Ok((user.0, name.to_string()))
}

async fn health(State(app): State<App>) -> &'static str {
    match sqlx::query("SELECT 1").execute(&app.pool).await {
        Ok(_) => "ok",
        Err(_) => "baza de date nu raspunde",
    }
}

// Scrie corpul cererii in fisierul temporar; intoarce (hash, marime).
async fn receive(body: Body, tmp: &std::path::Path) -> Result<(String, i64), Response> {
    let mut file = tokio::fs::File::create(tmp).await.map_err(internal)?;
    let mut hasher = blake3::Hasher::new();
    let mut size: i64 = 0;
    let mut stream = body.into_data_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| bad())?;
        hasher.update(&chunk);
        size += chunk.len() as i64;
        file.write_all(&chunk).await.map_err(internal)?;
    }
    file.sync_all().await.map_err(internal)?;
    Ok((hasher.finalize().to_hex().to_string(), size))
}

async fn upload(
    State(app): State<App>,
    Path(path): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Result<String, Response> {
    let (uid, name) = auth(&app, &headers).await?;
    let rel = safe(&path).ok_or_else(bad)?;
    let key = rel.to_string_lossy().to_string();
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = app.data.join("tmp").join(format!("{}-{n}.part", std::process::id()));

    let (hash, size) = match receive(body, &tmp).await {
        Ok(v) => v,
        Err(e) => {
            let _ = tokio::fs::remove_file(&tmp).await;
            return Err(e);
        }
    };

    let dest = app.data.join("files").join(&name).join(&rel);
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(internal)?;
    }
    tokio::fs::rename(&tmp, &dest).await.map_err(internal)?;

    sqlx::query(
        "INSERT INTO files (owner, path, size, hash) VALUES ($1, $2, $3, $4)
         ON CONFLICT (owner, path) DO UPDATE
         SET size = $3, hash = $4, version = files.version + 1, modified = now()",
    )
    .bind(uid)
    .bind(&key)
    .bind(size)
    .bind(&hash)
    .execute(&app.pool)
    .await
    .map_err(internal)?;

    Ok(format!("{hash} {size}\n"))
}

async fn download(
    State(app): State<App>,
    Path(path): Path<String>,
    headers: HeaderMap,
) -> Result<Body, Response> {
    let (_, name) = auth(&app, &headers).await?;
    let rel = safe(&path).ok_or_else(bad)?;
    let file = tokio::fs::File::open(app.data.join("files").join(&name).join(rel))
        .await
        .map_err(|_| StatusCode::NOT_FOUND.into_response())?;
    Ok(Body::from_stream(tokio_util::io::ReaderStream::new(file)))
}
