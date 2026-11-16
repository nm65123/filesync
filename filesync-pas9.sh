#!/bin/bash
# filesync, pasul 9: clientul de sincronizare (filesync-client), certificate cu autoritate proprie.
# Ruleaza pe serverul filesync:  bash filesync-pas9.sh
cd ~/filesync || exit 1
source ~/.cargo/env 2>/dev/null
grep -q '^\[workspace\]' Cargo.toml || printf '
[workspace]
members = ["client"]
' >> Cargo.toml
mkdir -p client/src
cat > client/Cargo.toml <<'FILESYNC_EOF'
[package]
name = "filesync-client"
version = "0.1.0"
edition = "2024"

[dependencies]
base64 = "0.22"
blake3 = "1.8.7"
serde = { version = "1.0.229", features = ["derive"] }
serde_json = "1.0.154"
ureq = "3.5.2"
FILESYNC_EOF
cat > client/src/main.rs <<'FILESYNC_EOF'
//! filesync-client: tine un director local la fel cu spatiul unui utilizator de pe server.

mod api;
mod scan;
mod state;
mod sync;

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

type Res<T> = Result<T, String>;

const HELP: &str = "\
filesync-client setup --url URL --user NUME --dir DIRECTOR [--ca-cert FISIER] [--token-file FISIER]
                                 leaga un director local de un cont de pe server
filesync-client once             o sincronizare, apoi se opreste
filesync-client run [--interval SECUNDE]
                                 sincronizeaza continuu (implicit la 10 secunde)
filesync-client status           arata configuratia si ce stie clientul

Optiuni comune:
  --profile NUME                 mai multe legaturi pe acelasi calculator (implicit: default)
  --allow-mass-delete            permite stergerea de pe server a multor fisiere deodata";

#[derive(Serialize, Deserialize)]
struct Config {
    url: String,
    user: String,
    token: String,
    dir: PathBuf,
    ca_cert: Option<PathBuf>,
}

/// Unde isi tine clientul configuratia si starea.
fn home(profile: &str) -> Res<PathBuf> {
    let base = if let Ok(dir) = std::env::var("FILESYNC_CLIENT_HOME") {
        PathBuf::from(dir)
    } else if cfg!(windows) {
        PathBuf::from(std::env::var("APPDATA").map_err(|_| "lipseste variabila APPDATA")?)
            .join("filesync-client")
    } else if let Ok(dir) = std::env::var("XDG_CONFIG_HOME") {
        PathBuf::from(dir).join("filesync-client")
    } else {
        PathBuf::from(std::env::var("HOME").map_err(|_| "lipseste variabila HOME")?)
            .join(".config")
            .join("filesync-client")
    };
    Ok(base.join(profile))
}

/// Valoarea unei optiuni de forma `--nume valoare`.
fn option(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn host_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .ok()
        .or_else(|| std::fs::read_to_string("/etc/hostname").ok())
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "calculator".into())
}

fn load(home: &Path) -> Res<(Config, api::Api)> {
    let path = home.join("config.json");
    let bytes = std::fs::read(&path)
        .map_err(|_| format!("nu exista configuratie ({}). Ruleaza intai `filesync-client setup`.", path.display()))?;
    let config: Config = serde_json::from_slice(&bytes).map_err(|e| format!("configuratie stricata: {e}"))?;
    let api = api::Api::new(&config.url, &config.user, &config.token, config.ca_cert.as_deref())?;
    Ok((config, api))
}

fn setup(home: &Path, args: &[String]) -> Res<()> {
    let need = |name: &str| option(args, name).ok_or(format!("lipseste {name}\n\n{HELP}"));
    let url = need("--url")?;
    let user = need("--user")?;
    let dir = PathBuf::from(need("--dir")?);
    if !url.starts_with("https://") && !url.starts_with("http://127.0.0.1") && !url.starts_with("http://localhost") {
        return Err("adresa trebuie sa inceapa cu https:// (tokenul nu se trimite necriptat)".into());
    }
    let token = match option(args, "--token-file") {
        Some(file) => std::fs::read_to_string(&file).map_err(|e| format!("nu pot citi {file}: {e}"))?,
        None => {
            eprint!("token pentru {user}: ");
            let mut line = String::new();
            std::io::stdin().read_line(&mut line).map_err(|e| e.to_string())?;
            line
        }
    };
    let token = token.trim().to_string();
    if token.is_empty() {
        return Err("tokenul este gol".into());
    }

    std::fs::create_dir_all(home).map_err(|e| format!("nu pot crea {}: {e}", home.display()))?;
    // Certificatul este copiat langa configuratie, ca sa nu depinda de fisierul original.
    let ca_cert = match option(args, "--ca-cert") {
        Some(file) => {
            let copy = home.join("server.crt");
            std::fs::copy(&file, &copy).map_err(|e| format!("nu pot citi certificatul {file}: {e}"))?;
            Some(copy)
        }
        None => None,
    };
    let api = api::Api::new(&url, &user, &token, ca_cert.as_deref())?;
    api.changes(i64::MAX).map_err(|e| format!("nu ma pot conecta la server: {e}"))?;

    std::fs::create_dir_all(&dir).map_err(|e| format!("nu pot crea {}: {e}", dir.display()))?;
    let dir = dir.canonicalize().map_err(|e| e.to_string())?;
    let config = Config { url, user, token, dir, ca_cert };
    let path = home.join("config.json");
    std::fs::write(&path, serde_json::to_vec_pretty(&config).map_err(|e| e.to_string())?)
        .map_err(|e| format!("nu pot scrie {}: {e}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    println!("Conectat la {} ca {}.", config.url, config.user);
    println!("Director sincronizat: {}", config.dir.display());
    println!("Porneste cu: filesync-client run");
    Ok(())
}

/// O sincronizare completa: repeta trecerile pana nu mai este nimic de facut.
fn sync(home: &Path, config: &Config, api: &api::Api, options: &sync::Options) -> Res<sync::Report> {
    let state_path = home.join("state.json");
    let mut state = state::State::load(&state_path)?;
    let mut total = sync::Report::default();
    for _ in 0..5 {
        let mut log = |line: String| println!("{line}");
        let result = sync::sync_once(api, &config.dir, &mut state, options, &mut log);
        state.save(&state_path)?; // si ce s-a facut pana la o eroare ramane tinut minte
        let report = result?;
        total.uploaded += report.uploaded;
        total.downloaded += report.downloaded;
        total.deleted_local += report.deleted_local;
        total.deleted_remote += report.deleted_remote;
        total.conflicts += report.conflicts;
        total.errors += report.errors;
        total.pending = report.pending;
        // Un conflict lasa o copie de urcat, deci mai trebuie o trecere.
        if !report.changed() {
            break;
        }
    }
    Ok(total)
}

fn summary(report: &sync::Report) -> String {
    format!(
        "{} urcate, {} coborate, {} sterse local, {} sterse pe server, {} conflicte, {} erori{}",
        report.uploaded,
        report.downloaded,
        report.deleted_local,
        report.deleted_remote,
        report.conflicts,
        report.errors,
        if report.pending > 0 { format!(", {} amanate", report.pending) } else { String::new() }
    )
}

fn start() -> Res<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("help");
    let home = home(&option(&args, "--profile").unwrap_or_else(|| "default".into()))?;
    let options = sync::Options {
        allow_mass_delete: args.iter().any(|a| a == "--allow-mass-delete"),
        host: host_name(),
        settle: std::env::var("FILESYNC_SETTLE").ok().and_then(|v| v.parse().ok()).unwrap_or(2),
    };
    match command {
        "setup" => setup(&home, &args),
        "once" => {
            let (config, api) = load(&home)?;
            let report = sync(&home, &config, &api, &options)?;
            println!("{}", summary(&report));
            if report.errors > 0 {
                return Err("sincronizare incompleta".into());
            }
            Ok(())
        }
        "run" => {
            let (config, api) = load(&home)?;
            let interval = option(&args, "--interval").and_then(|v| v.parse::<u64>().ok()).unwrap_or(10).max(1);
            println!("Sincronizez {} cu {} la fiecare {interval} secunde. Ctrl+C opreste.", config.dir.display(), config.url);
            loop {
                match sync(&home, &config, &api, &options) {
                    Ok(report) if report.changed() || report.errors > 0 => println!("{}", summary(&report)),
                    Ok(_) => {}
                    Err(e) => eprintln!("eroare: {e}"),
                }
                std::thread::sleep(std::time::Duration::from_secs(interval));
            }
        }
        "status" => {
            let (config, _) = load(&home)?;
            let state = state::State::load(&home.join("state.json"))?;
            println!("server:     {}", config.url);
            println!("utilizator: {}", config.user);
            println!("director:   {}", config.dir.display());
            println!("cunoscute:  {} fisiere si directoare (cursor {})", state.files.len(), state.cursor);
            Ok(())
        }
        "help" | "--help" | "-h" => {
            println!("{HELP}");
            Ok(())
        }
        other => Err(format!("comanda necunoscuta: {other}\n\n{HELP}")),
    }
}

fn main() {
    if let Err(e) = start() {
        eprintln!("eroare: {e}");
        std::process::exit(1);
    }
}
FILESYNC_EOF
cat > client/src/api.rs <<'FILESYNC_EOF'
//! Legatura cu serverul filesync (HTTPS).

use base64::Engine;
use serde::Deserialize;
use std::io::Read;
use std::path::Path;
use std::time::Duration;

#[derive(Deserialize, Clone, Debug)]
pub struct Entry {
    pub path: String,
    pub dir: bool,
    pub size: u64,
    pub hash: String,
    pub mtime: i64,
    pub version: i64,
    pub deleted: bool,
}

#[derive(Deserialize)]
struct ChangesReply {
    cursor: i64,
    more: bool,
    entries: Vec<Entry>,
}

#[derive(Debug)]
pub enum Fail {
    /// Pe server este alta versiune decat cea pe care o stiam (se rezolva la trecerea urmatoare).
    Conflict,
    /// Serverul a refuzat (cota depasita, cale invalida...). Textul este mesajul serverului.
    Refused(String),
    /// Reteaua sau serverul nu raspund.
    Network(String),
}

impl std::fmt::Display for Fail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Fail::Conflict => write!(f, "versiune schimbata pe server"),
            Fail::Refused(m) => write!(f, "refuzat de server: {m}"),
            Fail::Network(m) => write!(f, "retea: {m}"),
        }
    }
}

pub struct Api {
    agent: ureq::Agent,
    base: String,
    auth: String,
}

/// Citeste si calculeaza hash-ul a ceea ce trece prin el.
struct Hashing<R> {
    inner: R,
    hasher: blake3::Hasher,
}

impl<R: Read> Read for Hashing<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.hasher.update(&buf[..n]);
        Ok(n)
    }
}

/// Codifica o cale pentru adresa: fiecare segment separat, "/" ramane.
fn encode(path: &str) -> String {
    let mut out = String::new();
    for byte in path.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn network(e: ureq::Error) -> Fail {
    Fail::Network(e.to_string())
}

impl Api {
    pub fn new(url: &str, user: &str, token: &str, ca_cert: Option<&Path>) -> Result<Api, String> {
        let mut tls = ureq::tls::TlsConfig::builder();
        if let Some(path) = ca_cert {
            let pem = std::fs::read(path)
                .map_err(|e| format!("nu pot citi certificatul {}: {e}", path.display()))?;
            let cert = ureq::tls::Certificate::from_pem(&pem)
                .map_err(|e| format!("certificat invalid ({}): {e}", path.display()))?;
            tls = tls.root_certs(ureq::tls::RootCerts::new_with_certs(&[cert]));
        }
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(20)))
            .timeout_recv_response(Some(Duration::from_secs(120)))
            .tls_config(tls.build())
            .build()
            .into();
        let credentials = base64::engine::general_purpose::STANDARD.encode(format!("{user}:{token}"));
        Ok(Api {
            agent,
            base: url.trim_end_matches('/').to_string(),
            auth: format!("Basic {credentials}"),
        })
    }

    /// Mesajul de eroare al serverului, pentru raspunsurile care nu sunt 2xx.
    fn refused(mut response: ureq::http::Response<ureq::Body>) -> Fail {
        let status = response.status().as_u16();
        let body = response.body_mut().read_to_string().unwrap_or_default();
        match status {
            412 => Fail::Conflict,
            401 => Fail::Refused("utilizator sau token gresit".into()),
            _ => Fail::Refused(format!("{status} {}", body.trim())),
        }
    }

    /// Tot ce s-a schimbat pe server dupa `since`. Intoarce si noul cursor.
    pub fn changes(&self, since: i64) -> Result<(Vec<Entry>, i64), Fail> {
        let mut cursor = since;
        let mut all = Vec::new();
        loop {
            let url = format!("{}/api/changes?since={cursor}&limit=5000", self.base);
            let mut response = self
                .agent
                .get(&url)
                .header("Authorization", &self.auth)
                .call()
                .map_err(network)?;
            if !response.status().is_success() {
                return Err(Self::refused(response));
            }
            let text = response
                .body_mut()
                .with_config()
                .limit(512 * 1024 * 1024)
                .read_to_string()
                .map_err(network)?;
            let reply: ChangesReply =
                serde_json::from_str(&text).map_err(|e| Fail::Network(format!("raspuns invalid: {e}")))?;
            cursor = reply.cursor;
            all.extend(reply.entries);
            if !reply.more {
                return Ok((all, cursor));
            }
        }
    }

    /// Descarca un fisier in `dest`. Intoarce hash-ul continutului primit.
    pub fn download(&self, path: &str, dest: &Path) -> Result<String, Fail> {
        let url = format!("{}/files/{}", self.base, encode(path));
        let mut response = self
            .agent
            .get(&url)
            .header("Authorization", &self.auth)
            .call()
            .map_err(network)?;
        if !response.status().is_success() {
            return Err(Self::refused(response));
        }
        let mut reader = Hashing { inner: response.body_mut().as_reader(), hasher: blake3::Hasher::new() };
        let mut file = std::fs::File::create(dest).map_err(|e| Fail::Network(e.to_string()))?;
        std::io::copy(&mut reader, &mut file).map_err(|e| Fail::Network(e.to_string()))?;
        file.sync_all().map_err(|e| Fail::Network(e.to_string()))?;
        Ok(reader.hasher.finalize().to_hex().to_string())
    }

    /// Urca un fisier. `if_version` este versiunea pe care o stim pe server (0 = nu exista).
    /// Intoarce (versiunea noua, hash-ul continutului trimis).
    pub fn upload(
        &self,
        path: &str,
        source: &Path,
        size: u64,
        mtime: i64,
        if_version: i64,
    ) -> Result<(i64, String), Fail> {
        let url = format!("{}/files/{}", self.base, encode(path));
        let file = std::fs::File::open(source).map_err(|e| Fail::Network(e.to_string()))?;
        // Citim exact `size` octeti, cat am anuntat, chiar daca fisierul creste intre timp.
        let mut reader = Hashing { inner: file.take(size), hasher: blake3::Hasher::new() };
        let response = self
            .agent
            .put(&url)
            .header("Authorization", &self.auth)
            .header("Content-Length", &size.to_string())
            .header("X-OC-Mtime", &mtime.to_string())
            .header("X-Filesync-If-Version", &if_version.to_string())
            .send(ureq::SendBody::from_reader(&mut reader))
            .map_err(network)?;
        if !response.status().is_success() {
            return Err(Self::refused(response));
        }
        let version = response
            .headers()
            .get("x-filesync-version")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<i64>().ok())
            .ok_or_else(|| Fail::Network("serverul nu a trimis versiunea".into()))?;
        Ok((version, reader.hasher.finalize().to_hex().to_string()))
    }

    /// Sterge de pe server. Un director este sters doar daca este gol.
    /// Daca nu mai exista, este tot succes.
    pub fn delete(&self, path: &str, if_version: Option<i64>) -> Result<(), Fail> {
        let url = format!("{}/files/{}", self.base, encode(path));
        let mut request = self
            .agent
            .delete(&url)
            .header("Authorization", &self.auth)
            .header("X-Filesync-Only-Empty", "1");
        if let Some(version) = if_version {
            request = request.header("X-Filesync-If-Version", &version.to_string());
        }
        let response = request.call().map_err(network)?;
        match response.status().as_u16() {
            200..=299 | 404 => Ok(()),
            _ => Err(Self::refused(response)),
        }
    }

    pub fn mkdir(&self, path: &str) -> Result<(), Fail> {
        let url = format!("{}/api/dirs/{}", self.base, encode(path));
        let response = self
            .agent
            .put(&url)
            .header("Authorization", &self.auth)
            .send_empty()
            .map_err(network)?;
        if !response.status().is_success() {
            return Err(Self::refused(response));
        }
        Ok(())
    }
}
FILESYNC_EOF
cat > client/src/scan.rs <<'FILESYNC_EOF'
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
FILESYNC_EOF
cat > client/src/state.rs <<'FILESYNC_EOF'
//! Ce a vazut clientul la ultima sincronizare. Fata de aceasta stare se hotaraste
//! ce s-a schimbat local si ce s-a schimbat pe server.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Known {
    pub dir: bool,
    pub size: u64,
    pub mtime: i64,
    pub hash: String,
    pub version: i64,
}

#[derive(Serialize, Deserialize, Default)]
pub struct State {
    /// Pana unde a fost citit jurnalul de modificari al serverului.
    pub cursor: i64,
    pub files: BTreeMap<String, Known>,
}

impl State {
    pub fn load(path: &Path) -> Result<State, String> {
        match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| format!("fisierul de stare este stricat ({}): {e}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(State::default()),
            Err(e) => Err(format!("nu pot citi {}: {e}", path.display())),
        }
    }

    /// Scriere atomica: fisier temporar, apoi redenumire.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec(self).map_err(|e| e.to_string())?;
        std::fs::write(&tmp, bytes).map_err(|e| format!("nu pot scrie {}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, path).map_err(|e| format!("nu pot scrie {}: {e}", path.display()))
    }
}
FILESYNC_EOF
cat > client/src/sync.rs <<'FILESYNC_EOF'
//! Motorul de sincronizare: compara serverul, discul local si starea de la ultima
//! sincronizare, apoi aduce cele doua parti la fel.
//!
//! Reguli:
//! - schimbat doar pe server  -> se aduce local
//! - schimbat doar local      -> se urca pe server
//! - schimbat in ambele parti -> conflict: versiunea de pe server ramane sub numele
//!   original, cea locala este redenumita "nume (conflict data calculator).ext"
//! - stergerile se propaga in ambele sensuri; un fisier modificat castiga in fata unei stergeri

use crate::api::{Api, Entry, Fail};
use crate::scan::{self, Local, TEMP_PREFIX};
use crate::state::{Known, State};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Default, Debug)]
pub struct Report {
    pub uploaded: usize,
    pub downloaded: usize,
    pub deleted_local: usize,
    pub deleted_remote: usize,
    pub conflicts: usize,
    pub errors: usize,
    /// Lucruri amanate pentru trecerea urmatoare (fisier inca in scriere, versiune schimbata...).
    pub pending: usize,
}

impl Report {
    pub fn changed(&self) -> bool {
        self.uploaded + self.downloaded + self.deleted_local + self.deleted_remote + self.conflicts > 0
    }
}

pub struct Options {
    pub allow_mass_delete: bool,
    /// Numele calculatorului, folosit in numele copiilor de conflict.
    pub host: String,
    /// Un fisier modificat in ultimele `settle` secunde este lasat pentru trecerea urmatoare.
    pub settle: i64,
}

enum Remote {
    Changed(Entry),
    Deleted,
}

#[derive(PartialEq)]
enum LocalChange {
    Created,
    Changed,
    Deleted,
}

enum Action {
    Download(Entry),
    MkdirLocal(Entry),
    DeleteLocal,
    Upload { if_version: i64 },
    MkdirRemote,
    DeleteRemote { if_version: Option<i64> },
    Conflict(Entry),
    Record(Entry),
    Forget,
}

/// Rezultatul unui pas: facut, amanat pentru trecerea urmatoare, sau eroare.
enum Step {
    Done,
    Later(String),
    Failed(String),
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// "2026-11-16" din secunde Unix (UTC).
fn date(secs: i64) -> String {
    let z = secs.div_euclid(86_400) + 719_468;
    let (era, doe) = (z.div_euclid(146_097), z.rem_euclid(146_097));
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

/// Numele sub care este pastrata versiunea locala la un conflict.
fn conflict_name(root: &Path, path: &str, host: &str) -> String {
    let (dir, base) = match path.rfind('/') {
        Some(i) => (&path[..=i], &path[i + 1..]),
        None => ("", path),
    };
    let (stem, ext) = match base.rfind('.') {
        Some(i) if i > 0 => (&base[..i], &base[i..]),
        _ => (base, ""),
    };
    let label = format!("conflict {} {host}", date(now()));
    let mut candidate = format!("{dir}{stem} ({label}){ext}");
    let mut n = 2;
    while scan::local_path(root, &candidate).exists() {
        candidate = format!("{dir}{stem} ({label} {n}){ext}");
        n += 1;
    }
    candidate
}

/// Pe Windows unele nume nu pot exista pe disc.
fn representable(path: &str) -> bool {
    if !cfg!(windows) {
        return true;
    }
    path.split('/').all(|part| {
        !part.chars().any(|c| matches!(c, '<' | '>' | ':' | '"' | '|' | '?' | '*' | '\\') || c < ' ')
            && !part.ends_with('.')
            && !part.ends_with(' ')
    })
}

fn known_dir(version: i64) -> Known {
    Known { dir: true, size: 0, mtime: 0, hash: String::new(), version }
}

/// O trecere completa de sincronizare. `log` primeste cate o linie pentru fiecare lucru facut.
pub fn sync_once(
    api: &Api,
    root: &Path,
    state: &mut State,
    options: &Options,
    log: &mut dyn FnMut(String),
) -> Result<Report, String> {
    if !root.is_dir() {
        return Err(format!(
            "directorul {} nu exista (disc nemontat?). Nu sincronizez, ca sa nu sterg nimic de pe server.",
            root.display()
        ));
    }
    let (entries, new_cursor) = api.changes(state.cursor).map_err(|e| e.to_string())?;
    let mut remote: BTreeMap<String, Entry> = BTreeMap::new();
    for entry in entries {
        remote.insert(entry.path.clone(), entry); // ultima modificare a fiecarei cai
    }
    let local = scan::scan(root).map_err(|e| format!("nu pot citi {}: {e}", root.display()))?;
    let mut report = Report::default();
    let settle_after = now() - options.settle;

    // 1. Ce s-a schimbat, pentru fiecare cale, fata de ultima sincronizare.
    let paths: BTreeSet<String> = remote
        .keys()
        .chain(local.keys())
        .chain(state.files.keys())
        .cloned()
        .collect();
    let mut plan: BTreeMap<String, Action> = BTreeMap::new();
    for path in &paths {
        let known = state.files.get(path).cloned();
        let on_disk = local.get(path).copied();

        let remote_change = match remote.get(path) {
            Some(r) if r.deleted => known.as_ref().map(|_| Remote::Deleted),
            Some(r) => match &known {
                // Propria noastra modificare, intoarsa de jurnal.
                Some(k) if k.dir && r.dir => None,
                Some(k) if !k.dir && !r.dir && k.version == r.version => None,
                _ => Some(Remote::Changed(r.clone())),
            },
            None => None,
        };

        let mut local_hash: Option<String> = None;
        let local_change = match (&known, on_disk) {
            (None, None) => None,
            (Some(_), None) => Some(LocalChange::Deleted),
            (None, Some(_)) => Some(LocalChange::Created),
            (Some(k), Some(l)) if k.dir != l.dir => Some(LocalChange::Changed),
            (Some(_), Some(l)) if l.dir => None,
            (Some(k), Some(l)) if k.size == l.size && k.mtime == l.mtime => None,
            (Some(k), Some(l)) => {
                // Marimea sau data difera: hotaraste continutul.
                match scan::hash_file(&scan::local_path(root, path)) {
                    Ok(hash) if hash == k.hash => {
                        let mut same = k.clone();
                        same.size = l.size;
                        same.mtime = l.mtime;
                        state.files.insert(path.clone(), same);
                        None
                    }
                    Ok(hash) => {
                        local_hash = Some(hash);
                        Some(LocalChange::Changed)
                    }
                    Err(_) => Some(LocalChange::Changed),
                }
            }
        };

        // Un fisier care tocmai se scrie este lasat pentru trecerea urmatoare.
        if let (Some(change), Some(l)) = (&local_change, on_disk) {
            if *change != LocalChange::Deleted && !l.dir && l.mtime > settle_after {
                report.pending += 1;
                continue;
            }
        }

        let action = match (remote_change, local_change) {
            (None, None) => continue,
            (Some(Remote::Changed(r)), None) | (Some(Remote::Changed(r)), Some(LocalChange::Deleted)) => {
                if r.dir { Action::MkdirLocal(r) } else { Action::Download(r) }
            }
            (Some(Remote::Deleted), None) => Action::DeleteLocal,
            (Some(Remote::Deleted), Some(LocalChange::Deleted)) => Action::Forget,
            (None, Some(LocalChange::Deleted)) => {
                let k = known.as_ref().expect("stergere locala fara stare");
                Action::DeleteRemote { if_version: (!k.dir).then_some(k.version) }
            }
            (None, Some(_)) => {
                if on_disk.is_some_and(|l| l.dir) {
                    Action::MkdirRemote
                } else {
                    let version = known.as_ref().filter(|k| !k.dir).map(|k| k.version).unwrap_or(0);
                    Action::Upload { if_version: version }
                }
            }
            // Sters pe server, dar modificat local: versiunea locala castiga.
            (Some(Remote::Deleted), Some(_)) => {
                if on_disk.is_some_and(|l| l.dir) {
                    Action::MkdirRemote
                } else {
                    Action::Upload { if_version: 0 }
                }
            }
            (Some(Remote::Changed(r)), Some(_)) => {
                let l = on_disk.expect("modificare locala fara fisier");
                if r.dir && l.dir {
                    Action::Record(r)
                } else if !r.dir && !l.dir {
                    let hash = match local_hash {
                        Some(hash) => Some(hash),
                        None => scan::hash_file(&scan::local_path(root, path)).ok(),
                    };
                    if hash.as_deref() == Some(r.hash.as_str()) {
                        Action::Record(r) // acelasi continut in ambele parti
                    } else {
                        Action::Conflict(r)
                    }
                } else {
                    Action::Conflict(r)
                }
            }
        };
        plan.insert(path.clone(), action);
    }

    // 2. Protectie: multe stergeri de trimis serverului inseamna de obicei un director gol din greseala.
    let to_delete = plan.values().filter(|a| matches!(a, Action::DeleteRemote { .. })).count();
    if to_delete > 50 && to_delete * 2 > state.files.len() && !options.allow_mass_delete {
        return Err(format!(
            "{to_delete} din {} fisiere si directoare lipsesc local si ar fi sterse de pe server. \
             Daca le-ai sters intentionat, ruleaza din nou cu --allow-mass-delete.",
            state.files.len()
        ));
    }

    // 3. Executie: intai tot ce creeaza (de sus in jos), apoi stergerile (de jos in sus).
    let run = |path: &str, action: &Action, state: &mut State, report: &mut Report, log: &mut dyn FnMut(String)| {
        match execute(api, root, state, options, &local, path, action, report, log) {
            Step::Done => {}
            Step::Later(why) => {
                report.pending += 1;
                log(format!("amanat    {path} ({why})"));
            }
            Step::Failed(why) => {
                report.errors += 1;
                log(format!("EROARE    {path}: {why}"));
            }
        }
    };
    let is_delete = |a: &Action| matches!(a, Action::DeleteLocal | Action::DeleteRemote { .. });
    for (path, action) in plan.iter().filter(|(_, a)| !is_delete(a)) {
        run(path, action, state, &mut report, log);
    }
    for (path, action) in plan.iter().rev().filter(|(_, a)| is_delete(a)) {
        run(path, action, state, &mut report, log);
    }

    // Jurnalul este considerat citit doar daca tot ce a adus a fost aplicat.
    if report.errors == 0 && report.pending == 0 {
        state.cursor = new_cursor;
    }
    Ok(report)
}

#[allow(clippy::too_many_arguments)]
fn execute(
    api: &Api,
    root: &Path,
    state: &mut State,
    options: &Options,
    scanned: &BTreeMap<String, Local>,
    path: &str,
    action: &Action,
    report: &mut Report,
    log: &mut dyn FnMut(String),
) -> Step {
    let target = scan::local_path(root, path);
    match action {
        Action::Forget => {
            state.files.remove(path);
            Step::Done
        }
        Action::Record(r) => {
            let known = match scan::stat(&target) {
                Some(l) if l.dir => known_dir(r.version),
                Some(l) => Known { dir: false, size: l.size, mtime: l.mtime, hash: r.hash.clone(), version: r.version },
                None => return Step::Later("a disparut intre timp".into()),
            };
            state.files.insert(path.to_string(), known);
            Step::Done
        }
        Action::MkdirLocal(r) => {
            if !representable(path) {
                log(format!("sarit     {path} (nume care nu poate exista pe acest sistem)"));
                return Step::Done;
            }
            if let Err(e) = std::fs::create_dir_all(&target) {
                return Step::Failed(format!("nu pot crea directorul: {e}"));
            }
            state.files.insert(path.to_string(), known_dir(r.version));
            Step::Done
        }
        Action::Download(r) => download(api, root, state, scanned.get(path).copied(), path, r, report, log),
        Action::Conflict(r) => {
            let kept = conflict_name(root, path, &options.host);
            if let Err(e) = std::fs::rename(&target, scan::local_path(root, &kept)) {
                return Step::Failed(format!("nu pot pune deoparte versiunea locala: {e}"));
            }
            state.files.remove(path);
            report.conflicts += 1;
            log(format!("CONFLICT  {path}: versiunea locala pastrata ca \"{kept}\""));
            if r.dir {
                execute(api, root, state, options, scanned, path, &Action::MkdirLocal(r.clone()), report, log)
            } else {
                download(api, root, state, None, path, r, report, log)
            }
        }
        Action::DeleteLocal => {
            let known = state.files.get(path).cloned();
            match scan::stat(&target) {
                None => {}
                Some(l) if l.dir => {
                    if std::fs::remove_dir(&target).is_err() {
                        if scan::only_ignored(&target) {
                            let _ = std::fs::remove_dir_all(&target);
                        } else {
                            // Au ramas fisiere locale noi in el; raman si vor fi urcate.
                            state.files.remove(path);
                            return Step::Done;
                        }
                    }
                    report.deleted_local += 1;
                    log(format!("sters     {path}/ (local)"));
                }
                Some(l) => {
                    if known.as_ref().is_some_and(|k| k.size != l.size || k.mtime != l.mtime) {
                        return Step::Later("modificat local intre timp".into());
                    }
                    if let Err(e) = std::fs::remove_file(&target) {
                        return Step::Failed(format!("nu pot sterge: {e}"));
                    }
                    report.deleted_local += 1;
                    log(format!("sters     {path} (local)"));
                }
            }
            state.files.remove(path);
            Step::Done
        }
        Action::Upload { if_version } => {
            let Some(l) = scan::stat(&target).filter(|l| !l.dir) else {
                return Step::Later("a disparut intre timp".into());
            };
            if scanned.get(path) != Some(&l) {
                return Step::Later("inca se modifica".into());
            }
            match api.upload(path, &target, l.size, l.mtime, *if_version) {
                Ok((version, hash)) => {
                    state.files.insert(
                        path.to_string(),
                        Known { dir: false, size: l.size, mtime: l.mtime, hash, version },
                    );
                    report.uploaded += 1;
                    log(format!("urcat     {path}"));
                    Step::Done
                }
                Err(Fail::Conflict) => Step::Later("modificat si pe server".into()),
                Err(e) => Step::Failed(e.to_string()),
            }
        }
        Action::MkdirRemote => match api.mkdir(path) {
            Ok(()) => {
                state.files.insert(path.to_string(), known_dir(0));
                Step::Done
            }
            Err(e) => Step::Failed(e.to_string()),
        },
        Action::DeleteRemote { if_version } => match api.delete(path, *if_version) {
            Ok(()) => {
                state.files.remove(path);
                report.deleted_remote += 1;
                log(format!("sters     {path} (pe server)"));
                Step::Done
            }
            Err(Fail::Conflict) => Step::Later("modificat pe server intre timp".into()),
            // Directorul are pe server continut pe care nu l-am sters noi: ramane.
            Err(Fail::Refused(message)) if message.starts_with("409") => {
                state.files.remove(path);
                Step::Done
            }
            Err(e) => Step::Failed(e.to_string()),
        },
    }
}

#[allow(clippy::too_many_arguments)]
fn download(
    api: &Api,
    root: &Path,
    state: &mut State,
    seen: Option<Local>,
    path: &str,
    r: &Entry,
    report: &mut Report,
    log: &mut dyn FnMut(String),
) -> Step {
    if !representable(path) {
        log(format!("sarit     {path} (nume care nu poate exista pe acest sistem)"));
        return Step::Done;
    }
    let target = scan::local_path(root, path);
    let Some(parent) = target.parent() else {
        return Step::Failed("cale invalida".into());
    };
    if let Err(e) = std::fs::create_dir_all(parent) {
        return Step::Failed(format!("nu pot crea directorul: {e}"));
    }
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = parent.join(format!("{TEMP_PREFIX}{}-{n}", std::process::id()));
    let discard = |step: Step| {
        let _ = std::fs::remove_file(&tmp);
        step
    };
    match api.download(path, &tmp) {
        Ok(hash) if hash == r.hash => {}
        Ok(_) => return discard(Step::Later("s-a schimbat pe server in timpul descarcarii".into())),
        Err(Fail::Refused(m)) if m.starts_with("404") => {
            return discard(Step::Later("nu mai exista pe server".into()))
        }
        Err(e) => return discard(Step::Failed(e.to_string())),
    }
    // Fisierul local nu trebuie sa se fi schimbat de cand l-am citit.
    let current = scan::stat(&target);
    if current != seen {
        return discard(Step::Later("modificat local intre timp".into()));
    }
    if let Err(e) = scan::set_mtime(&tmp, r.mtime) {
        return discard(Step::Failed(format!("nu pot pune data: {e}")));
    }
    if let Err(e) = std::fs::rename(&tmp, &target) {
        return discard(Step::Failed(format!("nu pot scrie fisierul: {e}")));
    }
    state.files.insert(
        path.to_string(),
        Known { dir: false, size: r.size, mtime: r.mtime, hash: r.hash.clone(), version: r.version },
    );
    report.downloaded += 1;
    log(format!("coborat   {path}"));
    Step::Done
}
FILESYNC_EOF
cat > src/index.rs <<'FILESYNC_EOF'
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
FILESYNC_EOF
cat > src/http.rs <<'FILESYNC_EOF'
use crate::index;
use crate::util::{human, safe, set_mtime, verify_password};
use axum::{
    body::Body,
    extract::{Path, Query, Request, State},
    http::{header, HeaderMap, HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::{any, get},
    Json, Router,
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
    /// Serverul vorbeste HTTPS.
    pub tls: bool,
    /// Adresa publica (FILESYNC_URL), folosita in linkurile de partajare.
    pub public_url: Option<String>,
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
        .route("/files/{*path}", get(download).put(upload).delete(remove))
        .route("/api/changes", get(changes))
        .route("/api/dirs/{*path}", axum::routing::put(make_dir))
        .route("/dav", any(dav_root))
        .route("/dav/", any(dav_root))
        .route("/dav/{*path}", any(dav_path))
        .merge(crate::share::routes())
        .with_state(app)
}

pub fn text(status: StatusCode, message: impl Into<String>) -> Response {
    (status, message.into() + "\n").into_response()
}

pub fn internal<E: std::fmt::Display>(e: E) -> Response {
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

/// Versiunea pe care clientul crede ca o are serverul (antetul X-Filesync-If-Version).
/// 0 inseamna "calea nu trebuie sa existe". Fara antet nu se verifica nimic.
fn if_version(headers: &HeaderMap) -> Result<Option<i64>, Response> {
    match headers.get("x-filesync-if-version") {
        None => Ok(None),
        Some(value) => value
            .to_str()
            .ok()
            .and_then(|v| v.trim().parse::<i64>().ok())
            .map(Some)
            .ok_or_else(|| text(StatusCode::BAD_REQUEST, "X-Filesync-If-Version invalid.")),
    }
}

/// Raspunsul dat cand pe server este alta versiune decat cea asteptata de client.
fn version_mismatch(current: i64) -> Response {
    let mut resp = text(
        StatusCode::PRECONDITION_FAILED,
        "Pe server este alta versiune decat cea asteptata.",
    );
    resp.headers_mut().insert("x-filesync-version", HeaderValue::from(current));
    resp
}

fn content_length(headers: &HeaderMap) -> Option<u64> {
    headers.get(header::CONTENT_LENGTH)?.to_str().ok()?.parse().ok()
}

/// Verifica tokenul sau parola din antetul Authorization (HTTP Basic).
pub async fn auth(app: &App, headers: &HeaderMap) -> Result<User, Response> {
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
        let valid = tokio::task::spawn_blocking(move || verify_password(&password, &secret))
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
    let used = index::used(&app.pool, user.id).await.map_err(internal)? as u64;
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
    let expected = if_version(&headers)?;

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

    // De aici pana la commit, indexul utilizatorului este blocat pentru alte scrieri.
    let mut tx = match index::begin(&app.pool, user.id).await {
        Ok(tx) => tx,
        Err(e) => {
            let _ = tokio::fs::remove_file(&tmp).await;
            return Err(internal(e));
        }
    };
    if let Some(expected) = expected {
        let current = index::live_version(&mut tx, user.id, &key)
            .await
            .map_err(internal)?
            .unwrap_or(0);
        if current != expected {
            let _ = tokio::fs::remove_file(&tmp).await;
            return Err(version_mismatch(current));
        }
    }
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(internal)?;
    }
    tokio::fs::rename(&tmp, &dest).await.map_err(internal)?;
    let mtime = oc_mtime(&headers);
    if let Some(secs) = mtime {
        set_mtime(&dest, secs).map_err(internal)?;
    }
    // In index trecem data pe care o are fisierul pe disc.
    let on_disk = mtime.unwrap_or_else(|| index::disk_mtime(&dest));
    let version = index::record_file(&mut tx, user.id, &key, size, &hash, on_disk)
        .await
        .map_err(internal)?;
    tx.commit().await.map_err(internal)?;

    let mut resp = format!("{hash} {size}\n").into_response();
    resp.headers_mut().insert("x-filesync-version", HeaderValue::from(version));
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

/// Sterge un fisier sau un director cu tot continutul.
async fn remove(
    State(app): State<App>,
    Path(path): Path<String>,
    headers: HeaderMap,
) -> Result<StatusCode, Response> {
    let user = auth(&app, &headers).await?;
    let rel = safe(&path).ok_or_else(|| StatusCode::BAD_REQUEST.into_response())?;
    let root = app.data.join("files").join(&user.name);
    let target = root.join(&rel);
    let key = rel.to_string_lossy().to_string();
    let expected = if_version(&headers)?;
    let only_empty = headers.get("x-filesync-only-empty").is_some();

    let mut tx = index::begin(&app.pool, user.id).await.map_err(internal)?;
    let meta = tokio::fs::symlink_metadata(&target)
        .await
        .map_err(|_| StatusCode::NOT_FOUND.into_response())?;
    if meta.is_dir() {
        if only_empty {
            // Clientul de sincronizare sterge un director doar daca este gol si pe server.
            tokio::fs::remove_dir(&target).await.map_err(|_| {
                text(StatusCode::CONFLICT, "Directorul nu este gol.")
            })?;
        } else {
            tokio::fs::remove_dir_all(&target).await.map_err(internal)?;
        }
    } else {
        if let Some(expected) = expected {
            let current = index::live_version(&mut tx, user.id, &key)
                .await
                .map_err(internal)?
                .unwrap_or(0);
            if current != expected {
                return Err(version_mismatch(current));
            }
        }
        tokio::fs::remove_file(&target).await.map_err(internal)?;
    }
    tx.commit().await.map_err(internal)?;
    index::sync(&app.pool, &root, user.id, &key)
        .await
        .map_err(internal)?;
    Ok(StatusCode::NO_CONTENT)
}

/// Creeaza un director (cu parintii lui). Folosit de clientul de sincronizare.
async fn make_dir(
    State(app): State<App>,
    Path(path): Path<String>,
    headers: HeaderMap,
) -> Result<StatusCode, Response> {
    let user = auth(&app, &headers).await?;
    let rel = safe(path.trim_end_matches('/')).ok_or_else(|| StatusCode::BAD_REQUEST.into_response())?;
    let root = app.data.join("files").join(&user.name);
    let target = root.join(&rel);
    let existed = tokio::fs::metadata(&target).await.map(|m| m.is_dir()).unwrap_or(false);
    tokio::fs::create_dir_all(&target)
        .await
        .map_err(|_| text(StatusCode::CONFLICT, "Exista deja un fisier cu acest nume."))?;
    index::sync(&app.pool, &root, user.id, &rel.to_string_lossy())
        .await
        .map_err(internal)?;
    Ok(if existed { StatusCode::OK } else { StatusCode::CREATED })
}

#[derive(serde::Deserialize)]
struct ChangesQuery {
    since: Option<i64>,
    limit: Option<i64>,
}

#[derive(serde::Serialize)]
struct ChangesReply {
    /// Valoarea de trimis ca `since` la urmatoarea cerere.
    cursor: i64,
    /// true daca mai sunt modificari dupa cele intoarse acum.
    more: bool,
    entries: Vec<index::Entry>,
}

/// Jurnalul de modificari: tot ce s-a schimbat dupa `since` (0 = tot ce exista).
async fn changes(
    State(app): State<App>,
    Query(query): Query<ChangesQuery>,
    headers: HeaderMap,
) -> Result<Json<ChangesReply>, Response> {
    let user = auth(&app, &headers).await?;
    let since = query.since.unwrap_or(0).max(0);
    let limit = query.limit.unwrap_or(1000).clamp(1, 10_000);
    let (entries, more) = index::changes(&app.pool, user.id, since, limit)
        .await
        .map_err(internal)?;
    let cursor = entries.last().map(|e| e.seq).unwrap_or(since);
    Ok(Json(ChangesReply { cursor, more, entries }))
}

/// Calea din antetul Destination (MOVE si COPY), relativa la directorul utilizatorului.
fn destination(headers: &HeaderMap) -> Option<std::path::PathBuf> {
    let value = headers.get("destination")?.to_str().ok()?;
    let path = match value.find("://") {
        Some(i) => value[i + 3..].find('/').map(|j| &value[i + 3 + j..])?,
        None => value,
    };
    let rel = path.strip_prefix("/dav/")?.trim_end_matches('/');
    let decoded = percent_encoding::percent_decode_str(rel).decode_utf8().ok()?;
    safe(&decoded)
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
    let method = req.method().clone();
    let is_put = method == Method::PUT;
    let mtime = oc_mtime(req.headers());
    let moved_to = destination(req.headers());

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
        if let (Some(secs), Some(rel)) = (mtime, &target) {
            if set_mtime(&root.join(rel), secs).is_ok() {
                resp.headers_mut()
                    .insert("x-oc-mtime", HeaderValue::from_static("accepted"));
            }
        }
    }

    // Dupa orice operatie care a putut schimba ceva pe disc, aducem indexul la zi.
    let writes = matches!(method.as_str(), "PUT" | "DELETE" | "MKCOL" | "MOVE" | "COPY" | "LOCK");
    if writes && resp.status().as_u16() < 400 {
        let source = target.map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
        let dest = moved_to.map(|p| p.to_string_lossy().to_string());
        if let Err(e) = reindex(&app, &user, &root, method.as_str(), &source, dest.as_deref()).await {
            eprintln!("index: {e}");
        }
    }
    resp
}

async fn reindex(
    app: &App,
    user: &User,
    root: &std::path::Path,
    method: &str,
    source: &str,
    dest: Option<&str>,
) -> index::Res<()> {
    match (method, dest) {
        ("MOVE", Some(dest)) => {
            // Randurile se muta cu tot cu hash, ca fisierele sa nu fie citite din nou.
            index::carry(&app.pool, user.id, source, dest).await?;
            index::sync(&app.pool, root, user.id, dest).await?;
            index::sync(&app.pool, root, user.id, source).await?;
        }
        ("COPY", Some(dest)) => {
            index::sync(&app.pool, root, user.id, dest).await?;
        }
        _ => {
            index::sync(&app.pool, root, user.id, source).await?;
        }
    }
    Ok(())
}
FILESYNC_EOF
cat > src/admin.rs <<'FILESYNC_EOF'
use crate::index;
use crate::share;
use crate::util::{hash_password, human, parse_size, random_hex, valid_name};
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
filesync reindex [nume]           reface indexul dupa ce este pe disc
filesync share <nume> <cale> [--days N] [--password]
                                  creeaza un link public catre un fisier sau director
filesync shares [nume]            listeaza linkurile
filesync unshare <cod>            sterge un link
filesync gencert <nume|ip>... [--force]
                                  genereaza un certificat self-signed
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
        "users" => list_users(pool).await?,
        "share" => {
            let name = arg(args, 1, "numele")?;
            let path = arg(args, 2, "calea fisierului sau a directorului")?;
            let mut days = None;
            let mut password = None;
            let mut rest = args[3..].iter();
            while let Some(option) = rest.next() {
                match option.as_str() {
                    "--days" => {
                        let value = rest.next().ok_or("--days are nevoie de un numar")?;
                        days = Some(value.parse::<i64>().map_err(|_| "--days are nevoie de un numar")?);
                    }
                    "--password" => {
                        eprint!("parola pentru link: ");
                        let mut line = String::new();
                        std::io::stdin().read_line(&mut line)?;
                        let line = line.trim_end_matches(['\r', '\n']).to_string();
                        if line.is_empty() {
                            return Err("parola nu poate fi goala".into());
                        }
                        password = Some(line);
                    }
                    other => return Err(format!("optiune necunoscuta: {other}").into()),
                }
            }
            let (id,) = sqlx::query_as::<_, (i32,)>("SELECT id FROM users WHERE name = $1")
                .bind(name)
                .fetch_optional(pool)
                .await?
                .ok_or_else(|| format!("utilizator inexistent: {name}"))?;
            let (token, path, expires) =
                share::new_share(pool, data, id, name, path, password.as_deref(), days)
                    .await
                    .map_err(|(_, message)| message)?;
            eprintln!(
                "link creat pentru {name}:{path}{}{}",
                if password.is_some() { ", cu parola" } else { "" },
                match (days, expires) {
                    (Some(days), Some(_)) => format!(", expira in {days} zile"),
                    _ => ", fara expirare".to_string(),
                }
            );
            println!("{}", link(&token));
        }
        "shares" => {
            let only = args.get(1).map(String::as_str);
            let rows = sqlx::query_as::<_, (String, String, String, Option<String>, bool, i64)>(
                "SELECT s.token, u.name, s.path, to_char(s.expires, 'YYYY-MM-DD HH24:MI'),
                        s.password IS NOT NULL, s.downloads
                 FROM shares s JOIN users u ON u.id = s.owner
                 WHERE $1::text IS NULL OR u.name = $1
                 ORDER BY u.name, s.created",
            )
            .bind(only)
            .fetch_all(pool)
            .await?;
            println!(
                "{:<32} {:<16} {:<17} {:<6} {:>9}  {}",
                "COD", "UTILIZATOR", "EXPIRA", "PAROLA", "DESCARCAT", "CALE"
            );
            for (token, name, path, expires, password, downloads) in rows {
                println!(
                    "{:<32} {:<16} {:<17} {:<6} {:>9}  {}",
                    token,
                    name,
                    expires.as_deref().unwrap_or("niciodata"),
                    if password { "da" } else { "nu" },
                    downloads,
                    path
                );
            }
        }
        "unshare" => {
            let token = arg(args, 1, "codul linkului")?;
            let done = sqlx::query("DELETE FROM shares WHERE token = $1")
                .bind(token)
                .execute(pool)
                .await?;
            if done.rows_affected() == 0 {
                return Err(format!("link inexistent: {token}").into());
            }
            eprintln!("link sters");
        }
        "reindex" => {
            let only = args.get(1).map(String::as_str);
            let users = sqlx::query_as::<_, (i32, String)>("SELECT id, name FROM users ORDER BY name")
                .fetch_all(pool)
                .await?;
            if let Some(name) = only {
                if !users.iter().any(|(_, n)| n == name) {
                    return Err(format!("utilizator inexistent: {name}").into());
                }
            }
            for (id, name) in users.into_iter().filter(|(_, n)| only.is_none_or(|o| o == n)) {
                let root = data.join("files").join(&name);
                let stats = index::sync(pool, &root, id, "").await.map_err(|e| e.to_string())?;
                println!(
                    "{name}: {} noi, {} modificate, {} disparute",
                    stats.added, stats.updated, stats.removed
                );
            }
        }
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
    Ok(hash_password(password)?)
}

/// Adresa completa a unui link, daca stim sub ce adresa este vazut serverul.
fn link(token: &str) -> String {
    let base = std::env::var("FILESYNC_URL")
        .ok()
        .map(|url| url.trim_end_matches('/').to_string())
        .filter(|url| !url.is_empty())
        .or_else(|| {
            let listen: std::net::SocketAddr = std::env::var("FILESYNC_LISTEN").ok()?.parse().ok()?;
            (!listen.ip().is_unspecified()).then(|| format!("https://{listen}"))
        });
    match base {
        Some(base) => format!("{base}/s/{token}"),
        None => {
            eprintln!("(seteaza FILESYNC_URL ca sa primesti adresa completa)");
            format!("/s/{token}")
        }
    }
}

async fn list_users(pool: &PgPool) -> Res<()> {
    let rows = sqlx::query_as::<_, (String, Option<String>, Option<String>, Option<i64>, bool, bool, i64, i64)>(
        "SELECT u.name, u.email, u.grp, u.quota, u.admin, u.active,
                (SELECT count(*) FROM tokens t WHERE t.user_id = u.id),
                (SELECT COALESCE(SUM(f.size), 0)::bigint FROM files f
                 WHERE f.owner = u.id AND NOT f.deleted)
         FROM users u ORDER BY u.name",
    )
    .fetch_all(pool)
    .await?;
    println!(
        "{:<20} {:<28} {:<12} {:>10} {:>10} {:<5} {:<6} {}",
        "NUME", "EMAIL", "GRUP", "FOLOSIT", "COTA", "ADMIN", "ACTIV", "TOKENURI"
    );
    for (name, email, group, quota, admin, active, tokens, used) in rows {
        println!(
            "{:<20} {:<28} {:<12} {:>10} {:>10} {:<5} {:<6} {}",
            name,
            email.as_deref().unwrap_or("-"),
            group.as_deref().unwrap_or("-"),
            human(used as u64),
            quota.map(|q| human(q as u64)).unwrap_or_else(|| "nelimitat".into()),
            if admin { "da" } else { "nu" },
            if active { "da" } else { "nu" },
            tokens
        );
    }
    Ok(())
}

/// Certificate pentru HTTPS fara autoritate publica, facute cu `openssl`:
/// o autoritate proprie (CA), pe care calculatoarele o instaleaza o singura data,
/// si certificatul serverului, semnat de ea. Rularea din nou pastreaza autoritatea,
/// deci calculatoarele nu trebuie sa reinstaleze nimic.
fn gencert(data: &Path, args: &[String]) -> Res<()> {
    let force = args.iter().any(|a| a == "--force");
    let names: Vec<&String> = args.iter().filter(|a| *a != "--force").collect();
    if names.is_empty() {
        return Err("gencert: da cel putin un nume sau o adresa IP".into());
    }
    let dir = data.join("tls");
    std::fs::create_dir_all(&dir)?;
    let (ca, ca_key) = (dir.join("ca.pem"), dir.join("ca-key.pem"));
    let (cert, key) = (dir.join("cert.pem"), dir.join("key.pem"));
    let have_ca = ca.exists() && ca_key.exists();

    if cert.exists() && !have_ca && !force {
        return Err(format!(
            "exista un certificat de tip vechi: {}\n\
             Cel nou il inlocuieste, iar calculatoarele care l-au instalat vor trebui sa \
             instaleze o data certificatul nou. Daca asta vrei, adauga --force.",
            cert.display()
        )
        .into());
    }

    let openssl = |arguments: &[&std::ffi::OsStr]| -> Res<()> {
        let status = std::process::Command::new("openssl")
            .args(arguments)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map_err(|e| format!("nu pot rula openssl (este instalat?): {e}"))?;
        if !status.success() {
            return Err("openssl a esuat".into());
        }
        Ok(())
    };
    let os = std::ffi::OsStr::new;
    let ec = ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes"].map(os);

    // 1. Autoritatea, doar daca nu exista (sau la --force).
    if !have_ca || force {
        let mut arguments = vec![os("req"), os("-x509")];
        arguments.extend(ec);
        let subject = format!("/CN=filesync CA {}", names[0]);
        arguments.extend([
            os("-days"), os("3650"),
            os("-subj"), os(&subject),
            os("-addext"), os("basicConstraints=critical,CA:TRUE,pathlen:0"),
            os("-addext"), os("keyUsage=critical,keyCertSign,cRLSign"),
            os("-keyout"), ca_key.as_os_str(),
            os("-out"), ca.as_os_str(),
        ]);
        openssl(&arguments)?;
    }

    // 2. Certificatul serverului, semnat de autoritate.
    let san = names
        .iter()
        .map(|n| match n.parse::<std::net::IpAddr>() {
            Ok(_) => format!("IP:{n}"),
            Err(_) => format!("DNS:{n}"),
        })
        .collect::<Vec<_>>()
        .join(",");
    let (request, extensions, signed) = (dir.join("server.csr"), dir.join("server.ext"), dir.join("server.pem"));
    std::fs::write(
        &extensions,
        format!(
            "subjectAltName={san}\nbasicConstraints=critical,CA:FALSE\n\
             keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n"
        ),
    )?;
    let mut arguments = vec![os("req"), os("-new")];
    arguments.extend(ec);
    let subject = format!("/CN={}", names[0]);
    arguments.extend([os("-subj"), os(&subject), os("-keyout"), key.as_os_str(), os("-out"), request.as_os_str()]);
    openssl(&arguments)?;
    openssl(&[
        os("x509"), os("-req"), os("-in"), request.as_os_str(),
        os("-CA"), ca.as_os_str(), os("-CAkey"), ca_key.as_os_str(), os("-CAcreateserial"),
        os("-days"), os("825"), os("-extfile"), extensions.as_os_str(),
        os("-out"), signed.as_os_str(),
    ])?;
    // Serverul trimite certificatul lui urmat de cel al autoritatii.
    let mut chain = std::fs::read(&signed)?;
    chain.extend(std::fs::read(&ca)?);
    std::fs::write(&cert, chain)?;
    for leftover in [&request, &extensions, &signed, &dir.join("ca.srl")] {
        let _ = std::fs::remove_file(leftover);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for secret in [&key, &ca_key] {
            std::fs::set_permissions(secret, std::fs::Permissions::from_mode(0o600))?;
        }
    }

    println!("certificatul serverului: {} ({san}, 825 de zile)", cert.display());
    println!("certificatul de instalat pe calculatoare: {}", ca.display());
    println!("amprenta lui, de comparat la instalare:");
    let _ = std::process::Command::new("openssl")
        .args(["x509", "-noout", "-fingerprint", "-sha256", "-in"])
        .arg(&ca)
        .status();
    if have_ca && !force {
        println!("Autoritatea a ramas aceeasi: calculatoarele nu trebuie sa reinstaleze nimic.");
    }
    println!("Reporneste serverul ca sa foloseasca certificatul nou.");
    Ok(())
}
FILESYNC_EOF
cat > src/main.rs <<'FILESYNC_EOF'
mod admin;
mod http;
mod index;
mod share;
mod util;

use dav_server::{fakels::FakeLs, DavHandler};
use sqlx::postgres::PgPoolOptions;
use std::net::SocketAddr;
use std::path::PathBuf;

const SCHEMA: [&str; 15] = [
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
    // Indexul: directoare, stergeri pastrate ca randuri, numar de ordine al modificarii
    "ALTER TABLE files ADD COLUMN IF NOT EXISTS is_dir BOOLEAN NOT NULL DEFAULT false",
    "ALTER TABLE files ADD COLUMN IF NOT EXISTS deleted BOOLEAN NOT NULL DEFAULT false",
    "ALTER TABLE files ADD COLUMN IF NOT EXISTS seq BIGINT NOT NULL DEFAULT 0",
    "CREATE SEQUENCE IF NOT EXISTS files_seq",
    "CREATE INDEX IF NOT EXISTS files_owner_seq ON files (owner, seq)",
    // Randurile dinaintea indexului primesc si ele un numar de ordine
    "UPDATE files SET seq = nextval('files_seq') WHERE seq = 0",
    // Linkuri publice de partajare
    "CREATE TABLE IF NOT EXISTS shares (
        token     TEXT PRIMARY KEY,
        owner     INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        path      TEXT NOT NULL,
        password  TEXT,
        expires   TIMESTAMPTZ,
        created   TIMESTAMPTZ NOT NULL DEFAULT now(),
        downloads BIGINT NOT NULL DEFAULT 0
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
    // Calculatoarele instaleaza certificatul autoritatii, daca exista una.
    let ca = data.join("tls/ca.pem");
    let offered = if ca.exists() { ca } else { cert.clone() };
    let app = http::router(http::App {
        pool,
        data,
        dav,
        cert: tls.then_some(offered),
        tls,
        public_url: std::env::var("FILESYNC_URL")
            .ok()
            .map(|url| url.trim_end_matches('/').to_string())
            .filter(|url| !url.is_empty()),
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
- A sync client (`filesync-client`) keeps a local directory identical with
  the server, in both directions.
- Public share links for a file or a directory, optionally with a password
  and an expiry date.
- Every file and directory is indexed in PostgreSQL (size, BLAKE3 hash, date,
  version). A change feed tells sync clients what changed since their last
  visit.

Contents: [1. Install the server](#1-install-the-server) ·
[2. Manage users](#2-manage-users) ·
[3. Connect a computer](#3-connect-a-computer) ·
[4. Sync client](#4-sync-client) ·
[5. Update](#5-update) ·
[6. Settings](#6-settings) ·
[7. Known limitations](#7-known-limitations)

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

For example `filesync gencert 192.168.0.48 files.example.org`.

The command creates two things: a small certificate authority of your own,
and the server's certificate, signed by it. Computers install the
authority's certificate once (step 3.1). The command prints its **SHA-256
fingerprint**. Write it down: you need it in step 3.1.

The server's certificate is valid for 825 days. To renew it, or to add a
name or an address, run the same command again and restart the service. The
authority stays the same, so the computers do not have to do anything.
(`--force` replaces the authority too; then every computer has to repeat
step 3.1.)

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
| `filesync reindex [alice]`           | rebuild the index from the disk      |
| `filesync share alice docs/a.pdf`    | create a public link (see 3.6)       |
| `filesync shares [alice]`            | list the links                       |
| `filesync unshare CODE`              | delete a link                        |
| `filesync help`                      | list all commands                    |

Clients log in with the user name and either the password or, better, an
app token: a token can be deleted without changing the password.

When an upload would exceed the quota the server refuses it with
`507 Insufficient Storage` and a message such as
`Cota depasita: fisierul are 4.9 KiB, spatiu disponibil 524 B.`

---

## 3. Connect a computer

### 3.1 Trust the certificate (once per computer)

The server's certificate is signed by its own authority, which other
computers do not know, so each one has to be told to trust it. Download the
authority's certificate, check that its fingerprint is the one printed in
step 1.5, then install it. **If the fingerprints differ, stop:** the file is
not your server's certificate.

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
openssl x509 -in /var/lib/filesync/tls/ca.pem -noout -fingerprint -sha256
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
curl -u alice:TOKEN -X DELETE https://192.168.0.48:8443/files/docs/report.pdf
```

Add `-H "X-OC-Mtime: <unix seconds>"` on upload to set the file's date.
`DELETE` also removes a directory with everything in it.

Sync clients can make a write conditional with `X-Filesync-If-Version: N`:
the server answers `412` when the file's current version is not `N` (`0`
means "must not exist yet"). `PUT /api/dirs/<path>` creates a directory.

### 3.5 Change feed (for sync clients)

Every change gets a sequence number. A client remembers the last number it
has seen (its cursor) and asks for everything after it:

```sh
curl -u alice:TOKEN "https://192.168.0.48:8443/api/changes?since=0"
```

```json
{
  "cursor": 12,
  "more": false,
  "entries": [
    { "path": "docs", "dir": true, "size": 0, "hash": "", "mtime": 0,
      "version": 1, "seq": 11, "deleted": false },
    { "path": "docs/report.pdf", "dir": false, "size": 48213,
      "hash": "c450580a...", "mtime": 1600000000,
      "version": 1, "seq": 12, "deleted": false }
  ]
}
```

- `since=0` returns everything that exists. Send the returned `cursor` as
  `since` next time to get only what changed in between.
- `more: true` means there is more: ask again with the new cursor. `limit`
  sets the page size (default 1000, maximum 10000).
- A deleted file or directory appears with `"deleted": true`.
- `hash` is the BLAKE3 hash of the content, `mtime` the file date in Unix
  seconds, `version` counts the changes to that path.

### 3.6 Share links

A link gives anyone who has it access to one file or one directory, without
an account. On the server:

```sh
filesync share alice docs/report.pdf
filesync share alice photos --days 7 --password     # asks for the password
```

The command prints the address, for example
`https://192.168.0.48:8443/s/7b4ec5e01cd02facd44ef411ca29eb37`.

- A link to a file downloads it. A link to a directory shows a page with its
  content; everything below that directory is reachable, nothing above it.
- With `--password`, the browser asks for the password (the user name field
  can be left empty or filled with anything).
- With `--days N`, the link stops working after N days.
- `filesync shares` lists the links and how often each was used;
  `filesync unshare CODE` deletes one. Disabling a user disables the links.
- If the shared file or directory is moved, renamed or deleted, the link
  stops working.

Users can manage their own links through the API:

```sh
curl -u alice:TOKEN -H "Content-Type: application/json" \
     -d '{"path":"photos","days":7,"password":"secret"}' \
     https://192.168.0.48:8443/api/shares           # create; returns the url
curl -u alice:TOKEN https://192.168.0.48:8443/api/shares                # list
curl -u alice:TOKEN -X DELETE https://192.168.0.48:8443/api/shares/CODE  # delete
```

If people outside reach the server under another address than the one it
listens on (a domain name, a forwarded port), set `FILESYNC_URL` to that
address so the links are printed correctly.

---

## 4. Sync client

`filesync-client` keeps one local directory identical with a user's space on
the server. Files stay real files on both sides.

### 4.1 Build

On Linux, in the directory of the source code:

```sh
cargo build --release -p filesync-client
install -m 755 target/release/filesync-client /usr/local/bin/filesync-client
```

On Windows, install Rust from <https://rustup.rs> (the installer also offers
the Microsoft C++ build tools it needs) and Git from <https://git-scm.com>,
then in PowerShell:

```powershell
git clone https://github.com/nm65123/filesync.git
cd filesync
cargo build --release -p filesync-client
```

The program is `target\release\filesync-client.exe`; copy it wherever you
like. The Windows build has not been tested yet.

### 4.2 Connect

You need the server's address, a user name, an app token
(`filesync addtoken alice` on the server) and, for a server with its own
certificate authority, the certificate file from step 3.1.

```sh
filesync-client setup --url https://192.168.0.48:8443 --user alice \
    --dir ~/Files --ca-cert filesync.crt
```

It asks for the token, checks the connection and remembers everything. The
client uses the certificate file you give it; it does not look at the
certificates installed in the operating system. Leave `--ca-cert` out when
the server has a certificate from a public authority.

### 4.3 Run

```sh
filesync-client run          # keeps syncing every 10 seconds; Ctrl+C stops
filesync-client once         # one sync, then exit
filesync-client status
```

`--interval N` changes the pause. `--profile NAME` (on every command) lets
one computer sync several directories or accounts.

### 4.4 What it does

- New and changed files travel in both directions, with their original
  dates. Every download is verified against the server's hash.
- A file changed on both sides since the last sync is a **conflict**:
  nothing is lost. The server's version keeps the name, and the local one is
  kept as `name (conflict 2026-11-16 computer).ext` and uploaded too.
- Deletions travel in both directions. A file changed on one side wins over
  its deletion on the other.
- If more than 50 entries and more than half of everything would be deleted
  from the server in one go, the client stops and asks you to confirm with
  `--allow-mass-delete`. If the local directory is missing (a disk that is
  not mounted), it does nothing.
- Temporary and system files are not synced: `~$*`, `.~lock.*`, `*.tmp`,
  `*.part`, `*.crdownload`, `Thumbs.db`, `desktop.ini`, `.DS_Store`.
- A file that is still being written is left for the next round.

Settings and the sync state are kept in `~/.config/filesync-client/` (Linux,
macOS) or `%APPDATA%\filesync-client\` (Windows). The token is stored there
in plain text, readable only by your user.

---

## 5. Update

```sh
cd filesync
git pull
cargo build --release
install -m 755 target/release/filesync /usr/local/bin/filesync
systemctl restart filesync
```

Database changes are applied automatically at start. Rebuild the client the
same way (step 4.1) on the computers that use it.

---

## 6. Settings

Set in `/etc/filesync.env`; restart the service after a change.

| Variable                 | Default                       | Meaning                              |
|--------------------------|-------------------------------|--------------------------------------|
| `DATABASE_URL`           | (required)                    | PostgreSQL connection                |
| `FILESYNC_DATA`          | `/var/lib/filesync`           | files, temporary files, certificate  |
| `FILESYNC_LISTEN`        | `127.0.0.1:8090`              | address and port to listen on        |
| `FILESYNC_TLS_CERT`      | `$FILESYNC_DATA/tls/cert.pem` | certificate (PEM)                    |
| `FILESYNC_TLS_KEY`       | `$FILESYNC_DATA/tls/key.pem`  | private key (PEM)                    |
| `FILESYNC_INSECURE_HTTP` | unset                         | `1` allows plain HTTP on the network |
| `FILESYNC_URL`           | unset                         | public address, used in share links  |

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
| PostgreSQL database `filesync` | users, tokens, links, file index |

The index can always be rebuilt from the files with `filesync reindex`.

Back up the data directory and the database together.

---

## 7. Known limitations

- The disk is the source of truth and the index follows it. Files put
  directly into the data directory (not through the server) are not seen
  until you run `filesync reindex`. Run it also after a crash or a restore.
- A file uploaded through WebDAV is read once more after the upload, to
  compute its hash.
- WebDAV `COPY` is not checked against the quota.
- Sync client: it finds local changes by scanning the directory at every
  round (no file-system notifications yet); files are real files (no virtual
  files yet); only one client per profile may run at a time; names that
  differ only in letter case are not handled on Windows and macOS.
- Share links: wrong passwords are not rate-limited, and a shared directory
  cannot be downloaded as a single archive.
- The group and administrator flag are stored but not used yet.
- Server messages are in Romanian.

Planned: virtual files in the client (Windows Cloud Files, FUSE), delta
transfers (rsync algorithm).

## License

Licensed under either of Apache License 2.0 or MIT license, at your option.
FILESYNC_EOF
cargo build && cargo build -p filesync-client && echo "=== compilat cu succes ==="

