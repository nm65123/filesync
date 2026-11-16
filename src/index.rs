//! Indexul de fisiere din PostgreSQL.
//!
//! Discul este sursa de adevar. Dupa fiecare scriere, indexul este adus la zi, iar fiecare
//! modificare primeste un numar de ordine (`seq`). Un client de sincronizare cere
//! "tot ce s-a schimbat dupa seq N". Stergerile raman in index ca randuri marcate `deleted`.

use serde::Serialize;
use sqlx::PgPool;
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};

pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Serialize)]
pub struct Entry {
    pub path: String,
    pub dir: bool,
    pub size: i64,
    pub hash: String,
    pub mtime: i64,
    pub version: i64,
    pub seq: i64,
    pub deleted: bool,
}

#[derive(Default, Debug)]
pub struct Stats {
    pub added: usize,
    pub updated: usize,
    pub removed: usize,
}

struct OnDisk {
    dir: bool,
    size: i64,
    mtime: i64,
}

const UPSERT: &str = "
    INSERT INTO files (owner, path, is_dir, size, hash, modified, seq)
    VALUES ($1, $2, $3, $4, $5, to_timestamp($6), nextval('files_seq'))
    ON CONFLICT (owner, path) DO UPDATE
    SET is_dir = $3, size = $4, hash = $5, modified = to_timestamp($6),
        version = files.version + 1, seq = nextval('files_seq'), deleted = false
    RETURNING version";

/// Directoarele parinte ale unei cai: "a/b/c.txt" -> ["a", "a/b"].
fn parents(path: &str) -> Vec<&str> {
    path.match_indices('/').map(|(i, _)| &path[..i]).collect()
}

fn mtime_of(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Data fisierului de pe disc, in secunde.
pub fn disk_mtime(path: &Path) -> i64 {
    std::fs::metadata(path).map(|m| mtime_of(&m)).unwrap_or(0)
}

fn hash_file(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

/// Tot ce exista pe disc la `rel` si sub el (fara legaturi simbolice).
fn walk(root: &Path, rel: &str, found: &mut HashMap<String, OnDisk>) {
    let full = if rel.is_empty() { root.to_path_buf() } else { root.join(rel) };
    let Ok(meta) = std::fs::symlink_metadata(&full) else {
        return;
    };
    if meta.is_file() {
        found.insert(
            rel.to_string(),
            OnDisk { dir: false, size: meta.len() as i64, mtime: mtime_of(&meta) },
        );
    } else if meta.is_dir() {
        if !rel.is_empty() {
            found.insert(rel.to_string(), OnDisk { dir: true, size: 0, mtime: 0 });
        }
        let Ok(entries) = std::fs::read_dir(&full) else {
            return;
        };
        for entry in entries.flatten() {
            let Some(name) = entry.file_name().to_str().map(str::to_string) else {
                eprintln!("ignorat (nume care nu este UTF-8): {:?}", entry.path());
                continue;
            };
            let child = if rel.is_empty() { name } else { format!("{rel}/{name}") };
            walk(root, &child, found);
        }
    }
}

pub type Tx = sqlx::Transaction<'static, sqlx::Postgres>;

/// Incepe o scriere in indexul unui utilizator. Cat timp tranzactia este deschisa,
/// nimeni altcineva nu scrie in indexul lui.
pub async fn begin(pool: &PgPool, owner: i32) -> Res<Tx> {
    let mut tx = pool.begin().await?;
    lock(&mut tx, owner).await?;
    Ok(tx)
}

/// Versiunea curenta a unei cai; None daca nu exista (sau a fost stearsa).
pub async fn live_version(tx: &mut Tx, owner: i32, path: &str) -> Res<Option<i64>> {
    let row = sqlx::query_as::<_, (i64,)>(
        "SELECT version FROM files WHERE owner = $1 AND path = $2 AND NOT deleted",
    )
    .bind(owner)
    .bind(path)
    .fetch_optional(&mut **tx)
    .await?;
    Ok(row.map(|(version,)| version))
}

/// Inregistreaza un fisier scris prin API (hash-ul este deja cunoscut). Intoarce versiunea.
pub async fn record_file(
    tx: &mut Tx,
    owner: i32,
    path: &str,
    size: i64,
    hash: &str,
    mtime: i64,
) -> Res<i64> {
    for dir in parents(path) {
        ensure_dir(tx, owner, dir).await?;
    }
    let (version,) = sqlx::query_as::<_, (i64,)>(UPSERT)
        .bind(owner)
        .bind(path)
        .bind(false)
        .bind(size)
        .bind(hash)
        .bind(mtime as f64)
        .fetch_one(&mut **tx)
        .await?;
    Ok(version)
}

/// Scrierile in index ale unui utilizator se fac pe rand, ca ordinea `seq` sa fie
/// aceeasi cu ordinea in care devin vizibile.
async fn lock(tx: &mut sqlx::Transaction<'_, sqlx::Postgres>, owner: i32) -> Res<()> {
    sqlx::query("SELECT pg_advisory_xact_lock($1)")
        .bind(owner as i64)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

async fn ensure_dir(tx: &mut sqlx::Transaction<'_, sqlx::Postgres>, owner: i32, path: &str) -> Res<()> {
    sqlx::query(
        "INSERT INTO files (owner, path, is_dir, size, hash, seq)
         VALUES ($1, $2, true, 0, '', nextval('files_seq'))
         ON CONFLICT (owner, path) DO UPDATE
         SET is_dir = true, size = 0, hash = '', deleted = false,
             version = files.version + 1, seq = nextval('files_seq')
         WHERE files.deleted OR NOT files.is_dir",
    )
    .bind(owner)
    .bind(path)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Aduce indexul la zi cu discul pentru `rel` si tot ce este sub el
/// (`rel` gol inseamna tot spatiul utilizatorului). `root` este directorul utilizatorului.
pub async fn sync(pool: &PgPool, root: &Path, owner: i32, rel: &str) -> Res<Stats> {
    let (walk_root, walk_rel) = (root.to_path_buf(), rel.to_string());
    let disk = tokio::task::spawn_blocking(move || {
        let mut found = HashMap::new();
        walk(&walk_root, &walk_rel, &mut found);
        found
    })
    .await?;

    let rows = sqlx::query_as::<_, (String, bool, i64, i64)>(
        "SELECT path, is_dir, size, extract(epoch from modified)::bigint
         FROM files
         WHERE owner = $1 AND NOT deleted
           AND ($2 = '' OR path = $2 OR left(path, length($2) + 1) = $2 || '/')",
    )
    .bind(owner)
    .bind(rel)
    .fetch_all(pool)
    .await?;
    let known: HashMap<String, (bool, i64, i64)> =
        rows.into_iter().map(|(p, d, s, m)| (p, (d, s, m))).collect();

    // Ce s-a schimbat: nou, modificat (alta marime sau alta data), disparut.
    let mut stats = Stats::default();
    let mut changed: Vec<String> = Vec::new();
    for (path, on_disk) in &disk {
        match known.get(path) {
            Some((dir, size, mtime))
                if *dir == on_disk.dir
                    && (on_disk.dir || (*size == on_disk.size && *mtime == on_disk.mtime)) => {}
            Some(_) => {
                stats.updated += 1;
                changed.push(path.clone());
            }
            None => {
                stats.added += 1;
                changed.push(path.clone());
            }
        }
    }
    changed.sort(); // directoarele inaintea continutului lor
    let gone: Vec<String> = known.keys().filter(|p| !disk.contains_key(*p)).cloned().collect();
    stats.removed = gone.len();

    // Hash-ul se calculeaza doar pentru fisierele noi sau modificate.
    let mut hashes: HashMap<String, String> = HashMap::new();
    for path in &changed {
        if !disk[path].dir {
            let full: PathBuf = root.join(path);
            match tokio::task::spawn_blocking(move || hash_file(&full)).await? {
                Ok(hash) => {
                    hashes.insert(path.clone(), hash);
                }
                Err(e) => eprintln!("nu pot citi {path}: {e}"),
            }
        }
    }

    if changed.is_empty() && gone.is_empty() {
        return Ok(stats);
    }
    let mut tx = pool.begin().await?;
    lock(&mut tx, owner).await?;
    for path in &changed {
        let on_disk = &disk[path];
        let hash = match (on_disk.dir, hashes.get(path)) {
            (true, _) => "",
            (false, Some(hash)) => hash.as_str(),
            (false, None) => continue, // fisierul a disparut intre timp
        };
        for dir in parents(path) {
            if !known.contains_key(dir) && !disk.contains_key(dir) {
                ensure_dir(&mut tx, owner, dir).await?;
            }
        }
        sqlx::query(UPSERT)
            .bind(owner)
            .bind(path)
            .bind(on_disk.dir)
            .bind(on_disk.size)
            .bind(hash)
            .bind(on_disk.mtime as f64)
            .execute(&mut *tx)
            .await?;
    }
    if !gone.is_empty() {
        sqlx::query(
            "UPDATE files
             SET deleted = true, size = 0, version = version + 1, seq = nextval('files_seq')
             WHERE owner = $1 AND NOT deleted AND path = ANY($2)",
        )
        .bind(owner)
        .bind(&gone)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(stats)
}

/// Dupa o mutare pe disc, copiaza randurile din index de la `src` la `dst`, cu tot cu hash,
/// ca fisierele mutate sa nu mai fie citite din nou. `sync` face apoi restul.
pub async fn carry(pool: &PgPool, owner: i32, src: &str, dst: &str) -> Res<()> {
    let mut tx = pool.begin().await?;
    lock(&mut tx, owner).await?;
    sqlx::query(
        "INSERT INTO files (owner, path, is_dir, size, hash, modified, seq)
         SELECT owner, $3 || substr(path, length($2) + 1), is_dir, size, hash, modified,
                nextval('files_seq')
         FROM files
         WHERE owner = $1 AND NOT deleted
           AND (path = $2 OR left(path, length($2) + 1) = $2 || '/')
         ON CONFLICT (owner, path) DO UPDATE
         SET is_dir = EXCLUDED.is_dir, size = EXCLUDED.size, hash = EXCLUDED.hash,
             modified = EXCLUDED.modified, version = files.version + 1,
             seq = EXCLUDED.seq, deleted = false",
    )
    .bind(owner)
    .bind(src)
    .bind(dst)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

/// Spatiul folosit de un utilizator, din index.
pub async fn used(pool: &PgPool, owner: i32) -> Res<i64> {
    let (total,) = sqlx::query_as::<_, (i64,)>(
        "SELECT COALESCE(SUM(size), 0)::bigint FROM files WHERE owner = $1 AND NOT deleted",
    )
    .bind(owner)
    .fetch_one(pool)
    .await?;
    Ok(total)
}

/// Modificarile de dupa `since`, in ordine. Intoarce si daca mai sunt altele dupa `limit`.
pub async fn changes(pool: &PgPool, owner: i32, since: i64, limit: i64) -> Res<(Vec<Entry>, bool)> {
    let rows = sqlx::query_as::<_, (String, bool, i64, String, i64, i64, i64, bool)>(
        "SELECT path, is_dir, size, hash, extract(epoch from modified)::bigint,
                version, seq, deleted
         FROM files WHERE owner = $1 AND seq > $2 ORDER BY seq LIMIT $3",
    )
    .bind(owner)
    .bind(since)
    .bind(limit + 1)
    .fetch_all(pool)
    .await?;
    let more = rows.len() as i64 > limit;
    let entries = rows
        .into_iter()
        .take(limit as usize)
        .map(|(path, dir, size, hash, mtime, version, seq, deleted)| Entry {
            path,
            dir,
            size,
            hash,
            mtime,
            version,
            seq,
            deleted,
        })
        .collect();
    Ok((entries, more))
}
