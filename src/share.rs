//! Linkuri publice de partajare: `/s/<cod>` da acces fara cont la un fisier sau la un
//! director al unui utilizator, optional cu parola si cu data de expirare.

use crate::http::{auth, internal, text, App};
use crate::util::{hash_password, human, random_hex, safe, verify_password};
use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode, Uri},
    response::{Html, IntoResponse, Response},
    routing::{delete, get},
    Json, Router,
};
use base64::Engine;
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use sqlx::PgPool;
use std::path::PathBuf;

/// Caractere lasate neschimbate intr-un segment de adresa.
const SEGMENT: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'_').remove(b'.').remove(b'~');

pub fn routes() -> Router<App> {
    Router::new()
        .route("/api/shares", get(list).post(create))
        .route("/api/shares/{token}", delete(revoke))
        .route("/s/{token}", get(public_root))
        .route("/s/{token}/", get(public_root))
        .route("/s/{token}/{*path}", get(public_path))
}

#[derive(serde::Deserialize)]
struct NewShare {
    path: String,
    password: Option<String>,
    days: Option<i64>,
}

#[derive(serde::Serialize)]
pub struct ShareInfo {
    pub token: String,
    pub url: String,
    pub path: String,
    /// Momentul expirarii, in secunde Unix; null = nu expira.
    pub expires: Option<i64>,
    pub password: bool,
    pub downloads: i64,
}

/// Creeaza un link. Folosit atat de API cat si de linia de comanda.
pub async fn new_share(
    pool: &PgPool,
    data: &std::path::Path,
    owner: i32,
    owner_name: &str,
    path: &str,
    password: Option<&str>,
    days: Option<i64>,
) -> Result<(String, String, Option<i64>), (StatusCode, String)> {
    let bad = |m: &str| (StatusCode::BAD_REQUEST, m.to_string());
    let fail = |e: String| (StatusCode::INTERNAL_SERVER_ERROR, e);

    let rel = safe(path.trim_matches('/')).ok_or_else(|| bad("Cale invalida."))?;
    let key = rel.to_string_lossy().to_string();
    if tokio::fs::metadata(data.join("files").join(owner_name).join(&rel)).await.is_err() {
        return Err((StatusCode::NOT_FOUND, format!("Nu exista: {key}")));
    }
    if let Some(days) = days {
        if !(1..=3650).contains(&days) {
            return Err(bad("Numarul de zile trebuie sa fie intre 1 si 3650."));
        }
    }
    let password_hash = match password.filter(|p| !p.is_empty()) {
        Some(p) => {
            let p = p.to_string();
            Some(
                tokio::task::spawn_blocking(move || hash_password(&p))
                    .await
                    .map_err(|e| fail(e.to_string()))?
                    .map_err(fail)?,
            )
        }
        None => None,
    };
    let token = random_hex().map_err(|e| fail(e.to_string()))?[..32].to_string();
    let (expires,) = sqlx::query_as::<_, (Option<i64>,)>(
        "INSERT INTO shares (token, owner, path, password, expires)
         VALUES ($1, $2, $3, $4, now() + $5 * interval '1 day')
         RETURNING extract(epoch from expires)::bigint",
    )
    .bind(&token)
    .bind(owner)
    .bind(&key)
    .bind(password_hash)
    .bind(days.map(|d| d as f64))
    .fetch_one(pool)
    .await
    .map_err(|e| fail(e.to_string()))?;
    Ok((token, key, expires))
}

/// Adresa de baza pentru linkuri: FILESYNC_URL, altfel adresa la care a venit cererea.
fn base_url(app: &App, headers: &HeaderMap, uri: &Uri) -> String {
    if let Some(url) = &app.public_url {
        return url.clone();
    }
    // HTTP/2 trimite adresa in cerere, HTTP/1.1 in antetul Host.
    let host = uri
        .authority()
        .map(|a| a.as_str())
        .or_else(|| headers.get(header::HOST).and_then(|h| h.to_str().ok()))
        .unwrap_or("localhost");
    format!("{}://{host}", if app.tls { "https" } else { "http" })
}

async fn create(
    State(app): State<App>,
    uri: Uri,
    headers: HeaderMap,
    Json(body): Json<NewShare>,
) -> Result<Json<ShareInfo>, Response> {
    let user = auth(&app, &headers).await?;
    let (token, path, expires) = new_share(
        &app.pool,
        &app.data,
        user.id,
        &user.name,
        &body.path,
        body.password.as_deref(),
        body.days,
    )
    .await
    .map_err(|(status, message)| text(status, message))?;
    Ok(Json(ShareInfo {
        url: format!("{}/s/{token}", base_url(&app, &headers, &uri)),
        token,
        path,
        expires,
        password: body.password.is_some_and(|p| !p.is_empty()),
        downloads: 0,
    }))
}

async fn list(
    State(app): State<App>,
    uri: Uri,
    headers: HeaderMap,
) -> Result<Json<Vec<ShareInfo>>, Response> {
    let user = auth(&app, &headers).await?;
    let base = base_url(&app, &headers, &uri);
    let rows = sqlx::query_as::<_, (String, String, Option<i64>, bool, i64)>(
        "SELECT token, path, extract(epoch from expires)::bigint, password IS NOT NULL, downloads
         FROM shares WHERE owner = $1 ORDER BY created",
    )
    .bind(user.id)
    .fetch_all(&app.pool)
    .await
    .map_err(internal)?;
    Ok(Json(
        rows.into_iter()
            .map(|(token, path, expires, password, downloads)| ShareInfo {
                url: format!("{base}/s/{token}"),
                token,
                path,
                expires,
                password,
                downloads,
            })
            .collect(),
    ))
}

async fn revoke(
    State(app): State<App>,
    Path(token): Path<String>,
    headers: HeaderMap,
) -> Result<StatusCode, Response> {
    let user = auth(&app, &headers).await?;
    let done = sqlx::query("DELETE FROM shares WHERE token = $1 AND owner = $2")
        .bind(&token)
        .bind(user.id)
        .execute(&app.pool)
        .await
        .map_err(internal)?;
    if done.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND.into_response());
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn public_root(
    State(app): State<App>,
    Path(token): Path<String>,
    headers: HeaderMap,
) -> Response {
    serve(app, token, None, headers).await
}

async fn public_path(
    State(app): State<App>,
    Path((token, path)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    serve(app, token, Some(path), headers).await
}

fn not_found() -> Response {
    text(StatusCode::NOT_FOUND, "Linkul nu exista sau a expirat.")
}

fn ask_password() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        [(
            header::WWW_AUTHENTICATE,
            "Basic realm=\"Link protejat cu parola\", charset=\"UTF-8\"",
        )],
        "Acest link este protejat cu parola.\n",
    )
        .into_response()
}

/// Parola trimisa de browser (HTTP Basic); numele de utilizator este ignorat.
fn given_password(headers: &HeaderMap) -> Option<String> {
    let value = headers.get(header::AUTHORIZATION)?.to_str().ok()?.strip_prefix("Basic ")?;
    let decoded = base64::engine::general_purpose::STANDARD.decode(value).ok()?;
    let decoded = String::from_utf8(decoded).ok()?;
    decoded.split_once(':').map(|(_, password)| password.to_string())
}

async fn serve(app: App, token: String, sub: Option<String>, headers: HeaderMap) -> Response {
    // Linkul trebuie sa existe, sa nu fi expirat, iar contul proprietarului sa fie activ.
    let row = sqlx::query_as::<_, (String, Option<String>, String)>(
        "SELECT s.path, s.password, u.name
         FROM shares s JOIN users u ON u.id = s.owner
         WHERE s.token = $1 AND u.active AND (s.expires IS NULL OR s.expires > now())",
    )
    .bind(&token)
    .fetch_optional(&app.pool)
    .await;
    let (share_path, password, owner) = match row {
        Ok(Some(row)) => row,
        Ok(None) => return not_found(),
        Err(e) => return internal(e),
    };

    if let Some(hash) = password {
        let Some(given) = given_password(&headers) else {
            return ask_password();
        };
        let valid = tokio::task::spawn_blocking(move || verify_password(&hash, &given))
            .await
            .unwrap_or(false);
        if !valid {
            return ask_password();
        }
    }

    let base = app.data.join("files").join(&owner).join(&share_path);
    let sub = match sub.as_deref().map(|s| s.trim_matches('/')).filter(|s| !s.is_empty()) {
        Some(s) => match safe(s) {
            Some(p) => Some(p),
            None => return not_found(),
        },
        None => None,
    };
    let target = match &sub {
        Some(p) => base.join(p),
        None => base.clone(),
    };
    // Nimic din afara directorului partajat, nici prin legaturi simbolice.
    let (Ok(real_base), Ok(real_target)) = (
        tokio::fs::canonicalize(&base).await,
        tokio::fs::canonicalize(&target).await,
    ) else {
        return not_found();
    };
    if !real_target.starts_with(&real_base) {
        return not_found();
    }
    let Ok(meta) = tokio::fs::metadata(&real_target).await else {
        return not_found();
    };

    if meta.is_dir() {
        let shown = match &sub {
            Some(p) => PathBuf::from(&share_path).join(p),
            None => PathBuf::from(&share_path),
        };
        return match listing(&real_target, &token, sub.as_deref(), &shown).await {
            Ok(page) => (
                [
                    ("x-robots-tag", "noindex, nofollow"),
                    ("referrer-policy", "no-referrer"),
                    ("x-content-type-options", "nosniff"),
                ],
                Html(page),
            )
                .into_response(),
            Err(e) => internal(e),
        };
    }

    let file = match tokio::fs::File::open(&real_target).await {
        Ok(file) => file,
        Err(_) => return not_found(),
    };
    let _ = sqlx::query("UPDATE shares SET downloads = downloads + 1 WHERE token = $1")
        .bind(&token)
        .execute(&app.pool)
        .await;
    let name = real_target
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "fisier".into());
    Response::builder()
        .header(header::CONTENT_TYPE, "application/octet-stream")
        .header(header::CONTENT_LENGTH, meta.len())
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename*=UTF-8''{}", utf8_percent_encode(&name, SEGMENT)),
        )
        .header("x-content-type-options", "nosniff")
        .header("x-robots-tag", "noindex, nofollow")
        .body(Body::from_stream(tokio_util::io::ReaderStream::new(file)))
        .unwrap_or_else(|e| internal(e))
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn encode_path(path: &std::path::Path) -> String {
    path.components()
        .map(|c| utf8_percent_encode(&c.as_os_str().to_string_lossy(), SEGMENT).to_string())
        .collect::<Vec<_>>()
        .join("/")
}

/// "2026-11-16 10:57" (UTC) din secunde Unix.
fn format_time(secs: i64) -> String {
    let (days, rest) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let z = days + 719_468;
    let (era, doe) = (z.div_euclid(146_097), z.rem_euclid(146_097));
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02} {:02}:{:02}", rest / 3600, rest % 3600 / 60)
}

/// Pagina cu continutul unui director partajat.
async fn listing(
    dir: &std::path::Path,
    token: &str,
    sub: Option<&std::path::Path>,
    shown: &std::path::Path,
) -> std::io::Result<String> {
    let mut entries: Vec<(String, bool, u64, i64)> = Vec::new();
    let mut reader = tokio::fs::read_dir(dir).await?;
    while let Some(entry) = reader.next_entry().await? {
        let Ok(meta) = entry.metadata().await else { continue };
        if !meta.is_dir() && !meta.is_file() {
            continue;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_string) else { continue };
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        entries.push((name, meta.is_dir(), meta.len(), mtime));
    }
    entries.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.to_lowercase().cmp(&b.0.to_lowercase())));

    let prefix = match sub {
        Some(p) => format!("/s/{token}/{}/", encode_path(p)),
        None => format!("/s/{token}/"),
    };
    let title = escape(&shown.to_string_lossy());
    let mut rows = String::new();
    if let Some(p) = sub {
        let up = match p.parent().filter(|parent| !parent.as_os_str().is_empty()) {
            Some(parent) => format!("/s/{token}/{}/", encode_path(parent)),
            None => format!("/s/{token}/"),
        };
        rows.push_str(&format!("<tr><td><a href=\"{up}\">..</a></td><td></td><td></td></tr>\n"));
    }
    for (name, is_dir, size, mtime) in &entries {
        let link = format!("{prefix}{}", utf8_percent_encode(name, SEGMENT));
        let (label, size) = if *is_dir {
            (format!("{}/", escape(name)), String::new())
        } else {
            (escape(name), human(*size))
        };
        rows.push_str(&format!(
            "<tr><td><a href=\"{link}\">{label}</a></td><td class=\"n\">{size}</td><td class=\"n\">{}</td></tr>\n",
            format_time(*mtime)
        ));
    }
    if entries.is_empty() {
        rows.push_str("<tr><td colspan=\"3\">Directorul este gol.</td></tr>\n");
    }
    Ok(format!(
        "<!doctype html>\n<html lang=\"ro\"><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
<meta name=\"robots\" content=\"noindex, nofollow\">\
<title>{title}</title>\
<style>\
:root{{color-scheme:light dark}}\
body{{font:16px/1.5 system-ui,sans-serif;max-width:56rem;margin:2rem auto;padding:0 1rem}}\
h1{{font-size:1.25rem;overflow-wrap:anywhere}}\
table{{border-collapse:collapse;width:100%}}\
th,td{{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #8884}}\
.n{{white-space:nowrap;text-align:right;font-variant-numeric:tabular-nums}}\
a{{text-decoration:none;overflow-wrap:anywhere}}a:hover{{text-decoration:underline}}\
</style></head><body>\n<h1>{title}</h1>\n<table>\n\
<tr><th>Nume</th><th class=\"n\">M\u{103}rime</th><th class=\"n\">Modificat (UTC)</th></tr>\n\
{rows}</table>\n</body></html>\n"
    ))
}
