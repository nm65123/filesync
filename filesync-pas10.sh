#!/bin/bash
# filesync, pasul 10: finisari la client (asteptare la once, un singur client pe profil, jurnal, pornire automata pe Windows), README.
# Ruleaza pe serverul filesync:  bash filesync-pas10.sh
cd ~/filesync || exit 1
source ~/.cargo/env 2>/dev/null
cat > client/src/main.rs <<'FILESYNC_EOF'
//! filesync-client: tine un director local la fel cu spatiul unui utilizator de pe server.

mod api;
mod scan;
mod state;
mod sync;

use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

type Res<T> = Result<T, String>;

/// Fisierul de jurnal, cand clientul ruleaza in fundal (`--log`).
static LOG: OnceLock<Mutex<std::fs::File>> = OnceLock::new();

/// Scrie o linie: pe ecran sau, cu `--log`, in fisierul de jurnal, cu data si ora.
fn out(line: &str) {
    match LOG.get() {
        Some(file) => {
            if let Ok(mut file) = file.lock() {
                let _ = writeln!(file, "{} {line}", sync::timestamp());
            }
        }
        None => println!("{line}"),
    }
}

const HELP: &str = "\
filesync-client setup --url URL --user NUME --dir DIRECTOR [--ca-cert FISIER] [--token-file FISIER]
                                 leaga un director local de un cont de pe server
filesync-client once             o sincronizare, apoi se opreste
filesync-client run [--interval SECUNDE]
                                 sincronizeaza continuu (implicit la 10 secunde)
filesync-client status           arata configuratia si ce stie clientul
filesync-client autostart on|off
                                 (Windows) porneste clientul singur, in fundal, la autentificare

Optiuni comune:
  --profile NUME                 mai multe legaturi pe acelasi calculator (implicit: default)
  --log FISIER                   scrie in fisier in loc de ecran (pentru rularea in fundal)
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

/// Un singur client pe profil. Blocarea dispare singura cand programul se opreste.
fn lock(home: &Path) -> Res<std::fs::File> {
    let path = home.join("lock");
    let file = std::fs::File::options()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&path)
        .map_err(|e| format!("nu pot deschide {}: {e}", path.display()))?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(std::fs::TryLockError::WouldBlock) => {
            Err("un alt filesync-client ruleaza deja pe acest profil".into())
        }
        Err(std::fs::TryLockError::Error(e)) => Err(format!("nu pot bloca {}: {e}", path.display())),
    }
}

/// Pornire automata pe Windows: un mic script in dosarul Startup, care lanseaza
/// clientul fara fereastra, cu jurnalul scris in fisier.
fn autostart(home: &Path, profile: &str, args: &[String]) -> Res<()> {
    if !cfg!(windows) {
        return Err("autostart este pentru Windows. Pe Linux foloseste un serviciu systemd de utilizator (vezi README).".into());
    }
    let startup = PathBuf::from(std::env::var("APPDATA").map_err(|_| "lipseste variabila APPDATA")?)
        .join("Microsoft")
        .join("Windows")
        .join("Start Menu")
        .join("Programs")
        .join("Startup")
        .join(format!("filesync-client-{profile}.vbs"));
    match args.get(1).map(String::as_str) {
        Some("on") => {
            load(home)?; // trebuie sa existe o configuratie
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            let log = home.join("client.log");
            let script = format!(
                "CreateObject(\"WScript.Shell\").Run \"\"\"{}\"\" run --profile {profile} --log \"\"{}\"\"\", 0, False\r\n",
                exe.display(),
                log.display()
            );
            std::fs::write(&startup, script).map_err(|e| format!("nu pot scrie {}: {e}", startup.display()))?;
            let _ = std::process::Command::new("wscript.exe").arg(&startup).spawn();
            println!("Clientul porneste de acum singur la autentificare, in fundal.");
            println!("Program: {}  (nu il muta; daca il muti, ruleaza din nou `autostart on`)", exe.display());
            println!("Jurnal:  {}", log.display());
            Ok(())
        }
        Some("off") => {
            match std::fs::remove_file(&startup) {
                Ok(()) => println!("Pornirea automata a fost scoasa. Clientul care ruleaza acum se opreste la deconectare."),
                Err(_) => println!("Pornirea automata nu era activa."),
            }
            Ok(())
        }
        _ => Err("foloseste: filesync-client autostart on|off".into()),
    }
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
        let mut log = |line: String| out(&line);
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
    let profile = option(&args, "--profile").unwrap_or_else(|| "default".into());
    if profile.is_empty() || !profile.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err("numele profilului poate contine doar litere, cifre, - si _".into());
    }
    let home = home(&profile)?;
    if let Some(path) = option(&args, "--log") {
        let file = std::fs::File::options()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|e| format!("nu pot scrie jurnalul {path}: {e}"))?;
        let _ = LOG.set(Mutex::new(file));
    }
    let options = sync::Options {
        allow_mass_delete: args.iter().any(|a| a == "--allow-mass-delete"),
        host: host_name(),
        settle: std::env::var("FILESYNC_SETTLE").ok().and_then(|v| v.parse().ok()).unwrap_or(2),
    };
    match command {
        "setup" => setup(&home, &args),
        "autostart" => autostart(&home, &profile, &args),
        "once" => {
            let (config, api) = load(&home)?;
            let _guard = lock(&home)?;
            let mut report = sync(&home, &config, &api, &options)?;
            // Fisierele abia scrise sunt asteptate putin, apoi se mai incearca.
            for _ in 0..3 {
                if report.pending == 0 {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_secs(options.settle.max(0) as u64 + 1));
                let again = sync(&home, &config, &api, &options)?;
                report.uploaded += again.uploaded;
                report.downloaded += again.downloaded;
                report.deleted_local += again.deleted_local;
                report.deleted_remote += again.deleted_remote;
                report.conflicts += again.conflicts;
                report.errors += again.errors;
                report.pending = again.pending;
            }
            out(&summary(&report));
            if report.errors > 0 {
                return Err("sincronizare incompleta".into());
            }
            Ok(())
        }
        "run" => {
            let (config, api) = load(&home)?;
            let _guard = lock(&home)?;
            let interval = option(&args, "--interval").and_then(|v| v.parse::<u64>().ok()).unwrap_or(10).max(1);
            out(&format!(
                "Sincronizez {} cu {} la fiecare {interval} secunde.",
                config.dir.display(),
                config.url
            ));
            let mut last_error = String::new();
            loop {
                match sync(&home, &config, &api, &options) {
                    Ok(report) => {
                        if report.changed() || report.errors > 0 {
                            out(&summary(&report));
                        }
                        last_error.clear();
                    }
                    // Aceeasi eroare (de exemplu server oprit) este scrisa o singura data.
                    Err(e) if e != last_error => {
                        out(&format!("eroare: {e}"));
                        last_error = e;
                    }
                    Err(_) => {}
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

/// "2026-11-16 13:30:20" (UTC), pentru jurnal.
pub fn timestamp() -> String {
    let secs = now();
    let rest = secs.rem_euclid(86_400);
    format!("{} {:02}:{:02}:{:02}", date(secs), rest / 3600, rest % 3600 / 60, rest % 60)
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

### 4.2 Before you connect: certificate and token

The client needs two things from the server. Prepare them first.

**The certificate file** (only when the server uses its own certificate
authority, as in step 1.5). On the computer that will run the client:

```sh
curl -k https://192.168.0.48:8443/cert.crt -o filesync.crt
openssl x509 -in filesync.crt -noout -fingerprint -sha256
```

On Windows use `curl.exe` and the fingerprint lines from step 3.1. The
fingerprint must be the one printed by `gencert` on the server. The client
uses this file; it does not look at the certificates installed in the
operating system, so this step is needed even if you did step 3.1.

**An app token**, one for each computer. On the server:

```sh
set -a; . /etc/filesync.env; set +a
filesync adduser alice        # only if the account does not exist yet
filesync addtoken alice
```

`addtoken` prints the token, a line of 64 letters and digits, exactly once:
copy it now, it cannot be shown again. It also prints the token's id (8
characters). The token replaces the password for this computer. When a
computer is lost or retired, delete only its token and the others keep
working:

```sh
filesync tokens alice         # ids and creation dates
filesync deltoken alice ID
```

### 4.3 Connect

```sh
filesync-client setup --url https://192.168.0.48:8443 --user alice \
    --dir ~/Files --ca-cert filesync.crt
```

On Windows:

```powershell
.\filesync-client.exe setup --url https://192.168.0.48:8443 --user alice `
    --dir $HOME\Files --ca-cert $HOME\filesync.crt
```

It asks for the token (paste it and press Enter), checks the connection and
remembers everything. Start with a new, empty directory, or with one whose
content you want merged with the server. Leave `--ca-cert` out when the
server has a certificate from a public authority. `--token-file FILE` reads
the token from a file instead of asking.

To replace a token later, run `setup` again with the same directory; the
sync state is kept.

### 4.4 Run

```sh
filesync-client once         # one sync, then exit
filesync-client run          # keeps syncing every 10 seconds; Ctrl+C stops
filesync-client status
```

`--interval N` changes the pause. `--profile NAME` (on every command) lets
one computer sync several directories or accounts. Only one client can run
per profile; a second one refuses to start.

**In the background.** On Windows:

```powershell
.\filesync-client.exe autostart on      # autostart off  undoes it
```

The client then starts by itself at every sign-in, without a window, and
writes what it does to `%APPDATA%\filesync-client\default\client.log`. Do
not move the program afterwards (or run `autostart on` again from its new
place).

On Linux, as a systemd user service:

```sh
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/filesync-client.service <<'UNIT'
[Unit]
Description=filesync client

[Service]
ExecStart=/usr/local/bin/filesync-client run
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now filesync-client
journalctl --user -u filesync-client -n 20
```

Anywhere, `--log FILE` writes the messages to a file, with date and time
(UTC), instead of the screen.

### 4.5 What it does

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
cargo build -p filesync-client && echo "=== compilat cu succes ==="
