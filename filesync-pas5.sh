#!/bin/bash
# filesync, pasul 5: utilizatori (e-mail, grup, cota, admin, activ), HTTPS self-signed, administrare.
# Ruleaza pe serverul filesync:  bash filesync-pas5.sh   (sau lipeste tot continutul in terminal)
cd ~/filesync || exit 1
source ~/.cargo/env 2>/dev/null
cargo add axum-server -F tls-rustls
cat > src/util.rs <<'FILESYNC_EOF'
use std::io::Read;
use std::path::{Component, Path, PathBuf};

/// Nume de utilizator: litere mici, cifre, punct, - si _ (devine nume de director).
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '-' | '_'))
}

pub fn random_hex() -> std::io::Result<String> {
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Accepta doar cai relative simple: fara "..", fara "/" la inceput.
pub fn safe(path: &str) -> Option<PathBuf> {
    let p = Path::new(path);
    if path.is_empty() || !p.components().all(|c| matches!(c, Component::Normal(_))) {
        return None;
    }
    Some(p.components().collect())
}

pub fn set_mtime(path: &Path, secs: i64) -> std::io::Result<()> {
    let when = std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs as u64);
    std::fs::File::options().write(true).open(path)?.set_modified(when)
}

/// Spatiul ocupat de un director, in octeti (fara a urma legaturi simbolice).
pub fn dir_size(path: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else {
        return 0;
    };
    let mut total = 0;
    for entry in entries.flatten() {
        match entry.file_type() {
            Ok(t) if t.is_dir() => total += dir_size(&entry.path()),
            Ok(t) if t.is_file() => total += entry.metadata().map(|m| m.len()).unwrap_or(0),
            _ => {}
        }
    }
    total
}

/// "10G", "500M", "1T", "2048" (octeti) sau "none". Intoarce None daca textul e invalid,
/// Some(None) pentru nelimitat.
pub fn parse_size(text: &str) -> Option<Option<i64>> {
    let t = text.trim().to_ascii_lowercase();
    if matches!(t.as_str(), "none" | "nelimitat" | "unlimited") {
        return Some(None);
    }
    let t = t.trim_end_matches("ib").trim_end_matches('b');
    let (number, factor) = match t.chars().last()? {
        'k' => (&t[..t.len() - 1], 1i64 << 10),
        'm' => (&t[..t.len() - 1], 1i64 << 20),
        'g' => (&t[..t.len() - 1], 1i64 << 30),
        't' => (&t[..t.len() - 1], 1i64 << 40),
        _ => (t, 1),
    };
    let value: f64 = number.trim().parse().ok()?;
    if !value.is_finite() || value < 0.0 {
        return None;
    }
    Some(Some((value * factor as f64) as i64))
}

pub fn human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}
FILESYNC_EOF
cat > src/http.rs <<'FILESYNC_EOF'
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
FILESYNC_EOF
cat > src/admin.rs <<'FILESYNC_EOF'
use crate::util::{dir_size, human, parse_size, random_hex, valid_name};
use argon2::{
    password_hash::{rand_core::OsRng, PasswordHasher, SaltString},
    Argon2,
};
use sqlx::PgPool;
use std::path::Path;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

pub const HELP: &str = "\
filesync                          porneste serverul
filesync adduser <nume>           creeaza un utilizator (cere parola)
filesync passwd <nume>            schimba parola
filesync users                    listeaza utilizatorii
filesync quota <nume> <marime>    cota: 10G, 500M, 1T sau none (nelimitat)
filesync email <nume> <adresa>    adresa de e-mail (none = fara)
filesync group <nume> <grup>      grupul (none = fara)
filesync admin <nume> on|off      drept de administrator
filesync disable <nume>           dezactiveaza contul
filesync enable <nume>            reactiveaza contul
filesync addtoken <nume>          creeaza un token (parola de aplicatie)
filesync tokens <nume>            listeaza tokenurile
filesync deltoken <nume> <id|all> sterge un token sau pe toate
filesync gencert <nume|ip>...     genereaza un certificat self-signed
filesync help                     acest text";

fn arg<'a>(args: &'a [String], index: usize, what: &str) -> Res<&'a str> {
    args.get(index)
        .map(String::as_str)
        .ok_or_else(|| format!("lipseste: {what}").into())
}

fn none_or(value: &str) -> Option<&str> {
    (!matches!(value, "none" | "-" | "")).then_some(value)
}

/// Comenzi care nu au nevoie de baza de date. Intoarce true daca a rulat una.
pub fn local(data: &Path, args: &[String]) -> Res<bool> {
    match args.first().map(String::as_str) {
        Some("help" | "--help" | "-h") => println!("{HELP}"),
        Some("gencert") => gencert(data, &args[1..])?,
        _ => return Ok(false),
    }
    Ok(true)
}

/// Comenzi de administrare. Intoarce true daca a rulat una, false daca trebuie pornit serverul.
pub async fn run(pool: &PgPool, data: &Path, args: &[String]) -> Res<bool> {
    let Some(command) = args.first().map(String::as_str) else {
        return Ok(false);
    };
    match command {
        "adduser" => {
            let name = arg(args, 1, "numele")?;
            if !valid_name(name) {
                return Err("nume invalid: doar litere mici, cifre, punct, - si _".into());
            }
            let hash = read_password(name)?;
            let done = sqlx::query(
                "INSERT INTO users (name, password) VALUES ($1, $2) ON CONFLICT (name) DO NOTHING",
            )
            .bind(name)
            .bind(&hash)
            .execute(pool)
            .await?;
            if done.rows_affected() == 0 {
                return Err(format!("utilizatorul {name} exista deja (foloseste passwd)").into());
            }
            eprintln!("utilizator creat: {name}");
        }
        "passwd" => {
            let name = arg(args, 1, "numele")?;
            let hash = read_password(name)?;
            let done = sqlx::query("UPDATE users SET password = $2 WHERE name = $1")
                .bind(name)
                .bind(&hash)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "users" => list_users(pool, data).await?,
        "quota" => {
            let name = arg(args, 1, "numele")?;
            let quota = parse_size(arg(args, 2, "marimea (ex. 10G sau none)")?)
                .ok_or("marime invalida: foloseste 10G, 500M, 1T sau none")?;
            let done = sqlx::query("UPDATE users SET quota = $2 WHERE name = $1")
                .bind(name)
                .bind(quota)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "email" => {
            let name = arg(args, 1, "numele")?;
            let email = none_or(arg(args, 2, "adresa")?);
            let done = sqlx::query("UPDATE users SET email = $2 WHERE name = $1")
                .bind(name)
                .bind(email)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "group" => {
            let name = arg(args, 1, "numele")?;
            let group = none_or(arg(args, 2, "grupul")?);
            let done = sqlx::query("UPDATE users SET grp = $2 WHERE name = $1")
                .bind(name)
                .bind(group)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "admin" => {
            let name = arg(args, 1, "numele")?;
            let on = match arg(args, 2, "on sau off")? {
                "on" => true,
                "off" => false,
                _ => return Err("foloseste on sau off".into()),
            };
            let done = sqlx::query("UPDATE users SET admin = $2 WHERE name = $1")
                .bind(name)
                .bind(on)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "disable" | "enable" => {
            let name = arg(args, 1, "numele")?;
            let done = sqlx::query("UPDATE users SET active = $2 WHERE name = $1")
                .bind(name)
                .bind(command == "enable")
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "addtoken" => {
            let name = arg(args, 1, "numele")?;
            let token = random_hex()?;
            let hash = blake3::hash(token.as_bytes()).to_hex().to_string();
            let done = sqlx::query(
                "INSERT INTO tokens (hash, user_id) SELECT $1, id FROM users WHERE name = $2",
            )
            .bind(&hash)
            .bind(name)
            .execute(pool)
            .await?;
            if done.rows_affected() == 0 {
                return Err(format!("utilizator inexistent: {name}").into());
            }
            eprintln!("token creat, id {}", &hash[..8]);
            println!("{token}");
        }
        "tokens" => {
            let name = arg(args, 1, "numele")?;
            let rows = sqlx::query_as::<_, (String, String)>(
                "SELECT left(t.hash, 8), to_char(t.created, 'YYYY-MM-DD HH24:MI')
                 FROM tokens t JOIN users u ON u.id = t.user_id
                 WHERE u.name = $1 ORDER BY t.created",
            )
            .bind(name)
            .fetch_all(pool)
            .await?;
            for (id, created) in &rows {
                println!("{id}  {created}");
            }
            eprintln!("{} token(uri) pentru {name}", rows.len());
        }
        "deltoken" => {
            let name = arg(args, 1, "numele")?;
            let id = arg(args, 2, "id-ul tokenului sau all")?;
            let prefix = if id == "all" { "" } else { id };
            let done = sqlx::query(
                "DELETE FROM tokens
                 WHERE user_id = (SELECT id FROM users WHERE name = $1)
                   AND left(hash, length($2)) = $2",
            )
            .bind(name)
            .bind(prefix)
            .execute(pool)
            .await?;
            eprintln!("{} token(uri) sterse", done.rows_affected());
        }
        other => return Err(format!("comanda necunoscuta: {other}\n\n{HELP}").into()),
    }
    Ok(true)
}

fn changed(rows: u64, name: &str) -> Res<()> {
    if rows == 0 {
        return Err(format!("utilizator inexistent: {name}").into());
    }
    eprintln!("salvat: {name}");
    Ok(())
}

fn read_password(name: &str) -> Res<String> {
    eprint!("parola pentru {name}: ");
    let mut password = String::new();
    std::io::stdin().read_line(&mut password)?;
    let password = password.trim_end_matches(['\r', '\n']);
    if password.len() < 8 {
        return Err("parola trebuie sa aiba cel putin 8 caractere".into());
    }
    let salt = SaltString::generate(&mut OsRng);
    Ok(Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map_err(|e| e.to_string())?
        .to_string())
}

async fn list_users(pool: &PgPool, data: &Path) -> Res<()> {
    let rows = sqlx::query_as::<_, (String, Option<String>, Option<String>, Option<i64>, bool, bool, i64)>(
        "SELECT u.name, u.email, u.grp, u.quota, u.admin, u.active,
                (SELECT count(*) FROM tokens t WHERE t.user_id = u.id)
         FROM users u ORDER BY u.name",
    )
    .fetch_all(pool)
    .await?;
    println!(
        "{:<20} {:<28} {:<12} {:>10} {:>10} {:<5} {:<6} {}",
        "NUME", "EMAIL", "GRUP", "FOLOSIT", "COTA", "ADMIN", "ACTIV", "TOKENURI"
    );
    for (name, email, group, quota, admin, active, tokens) in rows {
        let used = dir_size(&data.join("files").join(&name));
        println!(
            "{:<20} {:<28} {:<12} {:>10} {:>10} {:<5} {:<6} {}",
            name,
            email.as_deref().unwrap_or("-"),
            group.as_deref().unwrap_or("-"),
            human(used),
            quota.map(|q| human(q as u64)).unwrap_or_else(|| "nelimitat".into()),
            if admin { "da" } else { "nu" },
            if active { "da" } else { "nu" },
            tokens
        );
    }
    Ok(())
}

/// Certificat self-signed pentru numele si adresele IP date, cu ajutorul `openssl`.
fn gencert(data: &Path, names: &[String]) -> Res<()> {
    if names.is_empty() {
        return Err("gencert: da cel putin un nume sau o adresa IP".into());
    }
    let dir = data.join("tls");
    std::fs::create_dir_all(&dir)?;
    let cert = dir.join("cert.pem");
    let key = dir.join("key.pem");
    let san = names
        .iter()
        .map(|n| match n.parse::<std::net::IpAddr>() {
            Ok(_) => format!("IP:{n}"),
            Err(_) => format!("DNS:{n}"),
        })
        .collect::<Vec<_>>()
        .join(",");

    let status = std::process::Command::new("openssl")
        .args(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"])
        .args(["-nodes", "-days", "825", "-subj"])
        .arg(format!("/CN={}", names[0]))
        .arg("-addext")
        .arg(format!("subjectAltName={san}"))
        .arg("-addext")
        .arg("extendedKeyUsage=serverAuth")
        .arg("-keyout")
        .arg(&key)
        .arg("-out")
        .arg(&cert)
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| format!("nu pot rula openssl (este instalat?): {e}"))?;
    if !status.success() {
        return Err("openssl a esuat".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600))?;
    }

    println!("certificat: {}", cert.display());
    println!("cheie:      {}", key.display());
    println!("valabil pentru: {san} (825 de zile)");
    let _ = std::process::Command::new("openssl")
        .args(["x509", "-noout", "-fingerprint", "-sha256", "-in"])
        .arg(&cert)
        .status();
    println!("Serverul il foloseste automat la urmatoarea pornire.");
    Ok(())
}
FILESYNC_EOF
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
        println!("ascult pe http://{addr} (fara TLS: ruleaza `filesync gencert`)");
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
FILESYNC_EOF
cargo build && echo "=== compilat cu succes ==="
