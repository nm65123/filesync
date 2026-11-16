use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
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

/// Hash Argon2 al unei parole, pentru pastrat in baza de date.
pub fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|e| e.to_string())
}

pub fn verify_password(hash: &str, password: &str) -> bool {
    PasswordHash::new(hash)
        .map(|parsed| Argon2::default().verify_password(password.as_bytes(), &parsed).is_ok())
        .unwrap_or(false)
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
