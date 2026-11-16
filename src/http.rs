use crate::util::{dir_size, human, safe, set_mtime};
use argon2::{
    password_hash::{PasswordHash, PasswordVerifier},
    Argon2,
};
use axum::{
    body::Body,
    extract::{Path, Request, State},
    http::{header, HeaderMap, HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::{any, get},
    Router,
};
use base64::Engine;
use dav_server::{localfs::LocalFs, DavConfig, DavHandler};
use futures_util::StreamExt;
use sqlx::PgPool;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::io::AsyncWriteExt;

#[derive(Clone)]
pub struct App {
    pub pool: PgPool,
    pub data: PathBuf,
    pub dav: DavHandler,
    pub cert: Option<PathBuf>,
}

pub struct User {
    pub id: i32,
    pub name: String,
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn router(app: App) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/cert.pem", get(cert))
        .route("/cert.crt", get(cert))
        .route("/files/{*path}", get(download).put(upload))
        .route("/dav", any(dav_root))
        .route("/dav/", any(dav_root))
        .route("/dav/{*path}", any(dav_path))
        .with_state(app)
}

fn text(status: StatusCode, message: impl Into<String>) -> Response {
    (status, message.into() + "\n").into_response()
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

/// Data originala a fisierului, trimisa de client in secunde (antetul X-OC-Mtime).
fn oc_mtime(headers: &HeaderMap) -> Option<i64> {
    headers
        .get("x-oc-mtime")?
        .to_str()
        .ok()?
        .trim()
        .parse::<i64>()
        .ok()
        .filter(|s| *s >= 0)
}

fn content_length(headers: &HeaderMap) -> Option<u64> {
    headers.get(header::CONTENT_LENGTH)?.to_str().ok()?.parse().ok()
}

/// Verifica tokenul sau parola din antetul Authorization (HTTP Basic).
async fn auth(app: &App, headers: &HeaderMap) -> Result<User, Response> {
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

    let (id, password, active) = sqlx::query_as::<_, (i32, String, bool)>(
        "SELECT id, password, active FROM users WHERE name = $1",
    )
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
    .bind(id)
    .fetch_optional(&app.pool)
    .await
    .map_err(internal)?;

    if by_token.is_none() {
        let secret = secret.to_string();
        let valid = tokio::task::spawn_blocking(move || {
            PasswordHash::new(&password)
                .map(|hash| Argon2::default().verify_password(secret.as_bytes(), &hash).is_ok())
                .unwrap_or(false)
        })
        .await
        .unwrap_or(false);
        if !valid {
            return Err(unauthorized());
        }
    }
    if !active {
        return Err(text(StatusCode::FORBIDDEN, "Contul este dezactivat."));
    }
    Ok(User { id, name: name.to_string() })
}

/// Spatiul disponibil pentru un fisier scris la `dest`; None inseamna cota nelimitata.
/// Fisierul existent la `dest` nu se numara, fiindca va fi inlocuit.
async fn available(app: &App, user: &User, dest: &std::path::Path) -> Result<Option<u64>, Response> {
    let (quota,) = sqlx::query_as::<_, (Option<i64>,)>("SELECT quota FROM users WHERE id = $1")
        .bind(user.id)
        .fetch_one(&app.pool)
        .await
        .map_err(internal)?;
    let Some(quota) = quota else {
        return Ok(None);
    };
    let root = app.data.join("files").join(&user.name);
    let used = tokio::task::spawn_blocking(move || dir_size(&root))
        .await
        .map_err(internal)?;
    let existing = match tokio::fs::metadata(dest).await {
        Ok(m) if m.is_file() => m.len(),
        _ => 0,
    };
    Ok(Some((quota as u64).saturating_sub(used.saturating_sub(existing))))
}

fn over_quota(available: u64, size: Option<u64>) -> Response {
    let message = match size {
        Some(size) => format!(
            "Cota depasita: fisierul are {}, spatiu disponibil {}.",
            human(size),
            human(available)
        ),
        None => format!("Cota depasita: spatiu disponibil {}.", human(available)),
    };
    text(StatusCode::INSUFFICIENT_STORAGE, message)
}

async fn health(State(app): State<App>) -> &'static str {
    match sqlx::query("SELECT 1").execute(&app.pool).await {
        Ok(_) => "ok",
        Err(_) => "baza de date nu raspunde",
    }
}

/// Certificatul serverului, ca sa poata fi descarcat si marcat ca de incredere.
async fn cert(State(app): State<App>) -> Response {
    let Some(path) = &app.cert else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match tokio::fs::read(path).await {
        Ok(pem) => (
            [
                (header::CONTENT_TYPE, "application/x-x509-ca-cert"),
                (header::CONTENT_DISPOSITION, "attachment; filename=\"filesync.crt\""),
            ],
            pem,
        )
            .into_response(),
        Err(e) => internal(e),
    }
}

/// Scrie corpul cererii in fisierul temporar; intoarce (hash, marime).
async fn receive(
    body: Body,
    tmp: &std::path::Path,
    limit: Option<u64>,
) -> Result<(String, i64), Response> {
    let mut file = tokio::fs::File::create(tmp).await.map_err(internal)?;
    let mut hasher = blake3::Hasher::new();
    let mut size: u64 = 0;
    let mut stream = body.into_data_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| StatusCode::BAD_REQUEST.into_response())?;
        size += chunk.len() as u64;
        if let Some(limit) = limit {
            if size > limit {
                return Err(over_quota(limit, None));
            }
        }
        hasher.update(&chunk);
        file.write_all(&chunk).await.map_err(internal)?;
    }
    file.sync_all().await.map_err(internal)?;
    Ok((hasher.finalize().to_hex().to_string(), size as i64))
}

async fn upload(
    State(app): State<App>,
    Path(path): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Result<Response, Response> {
    let user = auth(&app, &headers).await?;
    let rel = safe(&path).ok_or_else(|| StatusCode::BAD_REQUEST.into_response())?;
    let key = rel.to_string_lossy().to_string();
    let dest = app.data.join("files").join(&user.name).join(&rel);

    let limit = available(&app, &user, &dest).await?;
    if let (Some(limit), Some(length)) = (limit, content_length(&headers)) {
        if length > limit {
            return Err(over_quota(limit, Some(length)));
        }
    }

    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = app.data.join("tmp").join(format!("{}-{n}.part", std::process::id()));
    let (hash, size) = match receive(body, &tmp, limit).await {
        Ok(v) => v,
        Err(e) => {
            let _ = tokio::fs::remove_file(&tmp).await;
            return Err(e);
        }
    };

    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(internal)?;
    }
    tokio::fs::rename(&tmp, &dest).await.map_err(internal)?;
    let mtime = oc_mtime(&headers);
    if let Some(secs) = mtime {
        set_mtime(&dest, secs).map_err(internal)?;
    }

    sqlx::query(
        "INSERT INTO files (owner, path, size, hash, modified)
         VALUES ($1, $2, $3, $4, COALESCE(to_timestamp($5), now()))
         ON CONFLICT (owner, path) DO UPDATE
         SET size = $3, hash = $4, version = files.version + 1,
             modified = COALESCE(to_timestamp($5), now())",
    )
    .bind(user.id)
    .bind(&key)
    .bind(size)
    .bind(&hash)
    .bind(mtime.map(|s| s as f64))
    .execute(&app.pool)
    .await
    .map_err(internal)?;

    let mut resp = format!("{hash} {size}\n").into_response();
    if mtime.is_some() {
        resp.headers_mut()
            .insert("x-oc-mtime", HeaderValue::from_static("accepted"));
    }
    Ok(resp)
}

async fn download(
    State(app): State<App>,
    Path(path): Path<String>,
    headers: HeaderMap,
) -> Result<Body, Response> {
    let user = auth(&app, &headers).await?;
    let rel = safe(&path).ok_or_else(|| StatusCode::BAD_REQUEST.into_response())?;
    let file = tokio::fs::File::open(app.data.join("files").join(&user.name).join(rel))
        .await
        .map_err(|_| StatusCode::NOT_FOUND.into_response())?;
    Ok(Body::from_stream(tokio_util::io::ReaderStream::new(file)))
}

async fn dav_root(State(app): State<App>, req: Request) -> Response {
    serve_dav(app, None, req).await
}

async fn dav_path(State(app): State<App>, Path(path): Path<String>, req: Request) -> Response {
    serve_dav(app, Some(path), req).await
}

/// WebDAV: fiecare utilizator vede doar directorul lui.
async fn serve_dav(app: App, path: Option<String>, req: Request) -> Response {
    let user = match auth(&app, req.headers()).await {
        Ok(user) => user,
        Err(response) => return response,
    };
    let root = app.data.join("files").join(&user.name);
    if let Err(e) = tokio::fs::create_dir_all(&root).await {
        return internal(e);
    }
    let target = path.as_deref().and_then(safe);
    let is_put = req.method() == Method::PUT;
    let mtime = oc_mtime(req.headers());

    // Cota: la PUT verificam marimea anuntata de client inainte de a primi fisierul.
    if let (true, Some(rel)) = (is_put, &target) {
        match available(&app, &user, &root.join(rel)).await {
            Ok(Some(limit)) => match content_length(req.headers()) {
                Some(length) if length > limit => return over_quota(limit, Some(length)),
                Some(_) => {}
                None => {
                    return text(
                        StatusCode::LENGTH_REQUIRED,
                        "Contul are cota: clientul trebuie sa trimita Content-Length.",
                    )
                }
            },
            Ok(None) => {}
            Err(response) => return response,
        }
    }

    let config = DavConfig::new().filesystem(LocalFs::new(&root, false, false, false));
    let mut resp = app.dav.handle_with(config, req).await.into_response();

    // Dupa un PUT reusit, punem pe fisier data trimisa de client.
    if is_put && resp.status().is_success() {
        if let (Some(secs), Some(rel)) = (mtime, target) {
            if set_mtime(&root.join(rel), secs).is_ok() {
                resp.headers_mut()
                    .insert("x-oc-mtime", HeaderValue::from_static("accepted"));
            }
        }
    }
    resp
}
