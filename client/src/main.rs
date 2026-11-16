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
