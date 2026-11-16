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
