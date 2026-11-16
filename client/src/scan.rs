//! Citirea directorului local: ce exista, ce se ignora, hash-uri si date.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

pub const TEMP_PREFIX: &str = ".filesync-part-";

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Local {
    pub dir: bool,
    pub size: u64,
    pub mtime: i64,
}

/// Fisiere temporare si de sistem care nu se sincronizeaza.
pub fn ignored(name: &str) -> bool {
    let lower = name.to_lowercase();
    name.starts_with(TEMP_PREFIX)
        || name.starts_with("~$")
        || name.starts_with("._")
        || name.starts_with(".~lock.")
        || lower.ends_with(".tmp")
        || lower.ends_with(".part")
        || lower.ends_with(".crdownload")
        || matches!(lower.as_str(), "thumbs.db" | "desktop.ini" | ".ds_store")
}

pub fn mtime_of(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Starea unui singur fisier sau director; None daca nu exista (sau este legatura simbolica).
pub fn stat(path: &Path) -> Option<Local> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if meta.is_dir() {
        Some(Local { dir: true, size: 0, mtime: 0 })
    } else if meta.is_file() {
        Some(Local { dir: false, size: meta.len(), mtime: mtime_of(&meta) })
    } else {
        None
    }
}

/// Calea locala a unei intrari ("a/b.txt" -> radacina/a/b.txt, cu separatorul sistemului).
pub fn local_path(root: &Path, rel: &str) -> PathBuf {
    let mut path = root.to_path_buf();
    for part in rel.split('/') {
        path.push(part);
    }
    path
}

fn walk(dir: &Path, rel: &str, found: &mut BTreeMap<String, Local>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let Some(name) = entry.file_name().to_str().map(str::to_string) else {
            eprintln!("ignorat (nume care nu este UTF-8): {:?}", entry.path());
            continue;
        };
        if ignored(&name) {
            continue;
        }
        let Some(local) = stat(&entry.path()) else { continue };
        let child = if rel.is_empty() { name } else { format!("{rel}/{name}") };
        found.insert(child.clone(), local);
        if local.dir {
            walk(&entry.path(), &child, found)?;
        }
    }
    Ok(())
}

/// Tot ce exista in directorul sincronizat, cu cai relative separate prin "/".
pub fn scan(root: &Path) -> std::io::Result<BTreeMap<String, Local>> {
    let mut found = BTreeMap::new();
    walk(root, "", &mut found)?;
    Ok(found)
}

pub fn hash_file(path: &Path) -> std::io::Result<String> {
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

pub fn set_mtime(path: &Path, secs: i64) -> std::io::Result<()> {
    let when = std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs.max(0) as u64);
    std::fs::File::options().write(true).open(path)?.set_modified(when)
}

/// Un director in care au ramas doar fisiere ignorate (Thumbs.db etc.).
pub fn only_ignored(dir: &Path) -> bool {
    match std::fs::read_dir(dir) {
        Ok(entries) => entries.flatten().all(|e| {
            e.file_type().map(|t| t.is_file()).unwrap_or(false)
                && e.file_name().to_str().map(ignored).unwrap_or(false)
        }),
        Err(_) => false,
    }
}
