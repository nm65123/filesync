//! filesync-client: tine un director local la fel cu spatiul unui utilizator de pe server.

mod api;
#[cfg(windows)]
mod cloud;
#[cfg(unix)]
mod mount;
mod scan;
mod state;
mod sync;
mod watch;

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
filesync-client mount [DIRECTOR] [--cache-size 5G]
                                 (Linux, macOS) disc virtual: fisierele apar fara sa ocupe
                                 spatiu si sunt aduse la deschidere. Directorul si optiunile
                                 sunt tinute minte pentru data viitoare.
filesync-client cloud [DIRECTOR] [--cache-size 5G] [--free-after ZILE]
                                 (Windows) fisiere virtuale, ca OneDrive: apar in Explorer fara
                                 sa ocupe spatiu si sunt aduse la deschidere; cele nedeschise
                                 de ZILE zile sunt golite din nou (implicit 30; 0 = niciodata).
                                 Directorul si optiunile sunt tinute minte pentru data viitoare.
filesync-client cloud --unregister
                                 (Windows) scoate directorul dintre fisierele virtuale
filesync-client autostart on|off
                                 porneste clientul singur, in fundal, la autentificare
                                 (`run`, `cloud` sau `mount`, dupa cum este folosit profilul);
                                 Windows: Startup, macOS: LaunchAgent, Linux: systemd --user
filesync-client stop             opreste clientul care ruleaza in fundal pe acest profil

Optiuni comune:
  --profile NUME                 mai multe legaturi pe acelasi calculator (implicit: default)
  --log FISIER                   scrie in fisier in loc de ecran (pentru rularea in fundal)
  --allow-mass-delete            permite stergerea de pe server a multor fisiere deodata";

#[derive(Serialize, Deserialize)]
struct Config {
    url: String,
    user: String,
    token: String,
    /// Directorul sincronizat; lipseste la un profil folosit doar ca disc virtual.
    #[serde(default)]
    dir: Option<PathBuf>,
    ca_cert: Option<PathBuf>,
    /// (Windows) directorul cu fisiere virtuale, tinut minte de la prima rulare a lui `cloud`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cloud_dir: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cloud_cache_size: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cloud_free_after_days: Option<i64>,
    /// (Linux, macOS) directorul discului virtual, tinut minte de la prima rulare a lui `mount`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mount_dir: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mount_cache_size: Option<u64>,
}

impl Config {
    fn sync_dir(&self) -> Res<&Path> {
        self.dir.as_deref().ok_or_else(|| {
            "acest profil nu are un director de sincronizat (a fost facut fara --dir)".to_string()
        })
    }
}

/// "5G", "500M", "2T" sau un numar de octeti.
fn parse_size(text: &str) -> Option<u64> {
    let t = text.trim().to_ascii_lowercase();
    let t = t.trim_end_matches("ib").trim_end_matches('b');
    let (number, factor) = match t.chars().last()? {
        'k' => (&t[..t.len() - 1], 1u64 << 10),
        'm' => (&t[..t.len() - 1], 1u64 << 20),
        'g' => (&t[..t.len() - 1], 1u64 << 30),
        't' => (&t[..t.len() - 1], 1u64 << 40),
        _ => (t, 1),
    };
    let value: f64 = number.trim().parse().ok()?;
    (value.is_finite() && value >= 0.0).then(|| (value * factor as f64) as u64)
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
/// Opreste clientul care ruleaza pe profil, daca ruleaza. Intoarce true daca era unul.
fn stop_running(home: &Path) -> Res<bool> {
    let stop_file = home.join("stop");
    // Daca blocarea se poate lua, nu rula niciun client.
    if lock(home).is_ok() {
        let _ = std::fs::remove_file(&stop_file);
        return Ok(false);
    }
    std::fs::write(&stop_file, b"stop").map_err(|e| format!("nu pot scrie {}: {e}", stop_file.display()))?;
    for _ in 0..100 {
        std::thread::sleep(std::time::Duration::from_millis(200));
        if lock(home).is_ok() {
            let _ = std::fs::remove_file(&stop_file);
            return Ok(true);
        }
    }
    Err("clientul nu s-a oprit in 20 de secunde (poate termina o urcare); mai incearca".into())
}

/// Ce comanda porneste automat un profil, dupa cum este folosit.
fn autostart_command(config: &Config) -> Res<&'static str> {
    match (&config.cloud_dir, &config.mount_dir, &config.dir) {
        (Some(_), _, _) if cfg!(windows) => Ok("cloud"),
        (_, Some(_), _) if cfg!(unix) => Ok("mount"),
        (_, _, Some(_)) => Ok("run"),
        _ => Err("profilul nu are nici director de sincronizat, nici fisiere virtuale; ruleaza intai `setup --dir`, `mount DIRECTOR` sau `cloud DIRECTOR`".into()),
    }
}

fn autostart(home: &Path, profile: &str, args: &[String]) -> Res<()> {
    let on = match args.get(1).map(String::as_str) {
        Some("on") => true,
        Some("off") => false,
        _ => return Err("foloseste: filesync-client autostart on|off".into()),
    };
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    if cfg!(windows) {
        let startup = PathBuf::from(std::env::var("APPDATA").map_err(|_| "lipseste variabila APPDATA")?)
            .join("Microsoft")
            .join("Windows")
            .join("Start Menu")
            .join("Programs")
            .join("Startup")
            .join(format!("filesync-client-{profile}.vbs"));
        if !on {
            match std::fs::remove_file(&startup) {
                Ok(()) => println!("Pornirea automata a fost scoasa. Clientul care ruleaza acum se opreste la deconectare."),
                Err(_) => println!("Pornirea automata nu era activa."),
            }
            return Ok(());
        }
        let (config, _) = load(home)?;
        let command = autostart_command(&config)?;
        if stop_running(home)? {
            println!("Clientul pornit de mana a fost oprit.");
        }
        let log = home.join("client.log");
        let script = format!(
            "CreateObject(\"WScript.Shell\").Run \"\"\"{}\"\" {command} --profile {profile} --log \"\"{}\"\"\", 0, False\r\n",
            exe.display(),
            log.display()
        );
        std::fs::write(&startup, script).map_err(|e| format!("nu pot scrie {}: {e}", startup.display()))?;
        let _ = std::process::Command::new("wscript.exe").arg(&startup).spawn();
        println!("Clientul ({command}) porneste de acum singur la autentificare, in fundal.");
        println!("Program: {}  (nu il muta; daca il muti, ruleaza din nou `autostart on`)", exe.display());
        println!("Jurnal:  {}", log.display());
        return Ok(());
    }
    let user_home = PathBuf::from(std::env::var("HOME").map_err(|_| "lipseste variabila HOME")?);
    if cfg!(target_os = "macos") {
        let label = format!("ro.filesync.{profile}");
        let plist = user_home.join("Library").join("LaunchAgents").join(format!("{label}.plist"));
        let log = user_home.join("Library").join("Logs").join(format!("filesync-client-{profile}.log"));
        let uid = std::process::Command::new("id").arg("-u").output().ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .ok_or("nu pot afla uid-ul")?;
        let domain = format!("gui/{uid}");
        // Oprim ce era pornit sub aceasta eticheta (daca era).
        let _ = std::process::Command::new("launchctl").args(["bootout", &format!("{domain}/{label}")])
            .stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
        if !on {
            match std::fs::remove_file(&plist) {
                Ok(()) => println!("Pornirea automata a fost scoasa si clientul oprit."),
                Err(_) => println!("Pornirea automata nu era activa."),
            }
            return Ok(());
        }
        let (config, _) = load(home)?;
        let command = autostart_command(&config)?;
        if stop_running(home)? {
            println!("Clientul pornit de mana a fost oprit.");
        }
        let content = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{exe}</string>
        <string>{command}</string>
        <string>--profile</string>
        <string>{profile}</string>
        <string>--log</string>
        <string>{log}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
</dict>
</plist>
"#,
            exe = exe.display(),
            log = log.display()
        );
        if let Some(dir) = plist.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        std::fs::write(&plist, content).map_err(|e| format!("nu pot scrie {}: {e}", plist.display()))?;
        let status = std::process::Command::new("launchctl").args(["bootstrap", &domain]).arg(&plist).status()
            .map_err(|e| format!("launchctl: {e}"))?;
        if !status.success() {
            return Err(format!("launchctl bootstrap a esuat pentru {}", plist.display()));
        }
        println!("Clientul ({command}) porneste de acum singur la autentificare, in fundal.");
        println!("Program: {}  (nu il muta; daca il muti, ruleaza din nou `autostart on`)", exe.display());
        println!("Jurnal:  {}", log.display());
        println!("Oprire:  filesync-client autostart off --profile {profile}  (sau `stop`, pana la urmatoarea autentificare)");
        return Ok(());
    }
    // Linux: serviciu systemd de utilizator.
    let unit_name = format!("filesync-client-{profile}.service");
    let unit = user_home.join(".config").join("systemd").join("user").join(&unit_name);
    let systemctl = |args: &[&str]| std::process::Command::new("systemctl").arg("--user").args(args).status();
    if !on {
        let _ = systemctl(&["disable", "--now", &unit_name]);
        match std::fs::remove_file(&unit) {
            Ok(()) => {
                let _ = systemctl(&["daemon-reload"]);
                println!("Pornirea automata a fost scoasa si clientul oprit.");
            }
            Err(_) => println!("Pornirea automata nu era activa."),
        }
        return Ok(());
    }
    let (config, _) = load(home)?;
    let command = autostart_command(&config)?;
    if stop_running(home)? {
        println!("Clientul pornit de mana a fost oprit.");
    }
    let content = format!(
        "[Unit]\nDescription=filesync client ({profile})\n\n[Service]\nExecStart={} {command} --profile {profile}\nRestart=on-failure\nRestartSec=30\n\n[Install]\nWantedBy=default.target\n",
        exe.display()
    );
    if let Some(dir) = unit.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    std::fs::write(&unit, content).map_err(|e| format!("nu pot scrie {}: {e}", unit.display()))?;
    let ok = systemctl(&["daemon-reload"]).is_ok_and(|s| s.success())
        && systemctl(&["enable", "--now", &unit_name]).is_ok_and(|s| s.success());
    if !ok {
        return Err("systemctl --user a esuat (exista systemd de utilizator?)".into());
    }
    println!("Clientul ({command}) porneste de acum singur la autentificare, in fundal.");
    println!("Program: {}  (nu il muta; daca il muti, ruleaza din nou `autostart on`)", exe.display());
    println!("Jurnal:  journalctl --user -u {unit_name}");
    Ok(())
}

fn save_config(home: &Path, config: &Config) -> Res<()> {
    let path = home.join("config.json");
    std::fs::write(&path, serde_json::to_vec_pretty(config).map_err(|e| e.to_string())?)
        .map_err(|e| format!("nu pot scrie {}: {e}", path.display()))
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
    let dir = option(args, "--dir").map(PathBuf::from);
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

    let dir = match dir {
        Some(dir) => {
            std::fs::create_dir_all(&dir).map_err(|e| format!("nu pot crea {}: {e}", dir.display()))?;
            Some(dir.canonicalize().map_err(|e| e.to_string())?)
        }
        None => None,
    };
    let config = Config {
        url,
        user,
        token,
        dir,
        ca_cert,
        cloud_dir: None,
        cloud_cache_size: None,
        cloud_free_after_days: None,
        mount_dir: None,
        mount_cache_size: None,
    };
    save_config(home, &config)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(home.join("config.json"), std::fs::Permissions::from_mode(0o600));
    }
    println!("Conectat la {} ca {}.", config.url, config.user);
    match &config.dir {
        Some(dir) => {
            println!("Director sincronizat: {}", dir.display());
            println!("Porneste cu: filesync-client run");
        }
        None => println!("Profil fara director sincronizat. Foloseste: filesync-client mount DIRECTOR"),
    }
    Ok(())
}

/// O sincronizare completa: repeta trecerile pana nu mai este nimic de facut.
fn sync(home: &Path, config: &Config, api: &api::Api, options: &sync::Options) -> Res<sync::Report> {
    let state_path = home.join("state.json");
    let mut state = state::State::load(&state_path)?;
    let mut total = sync::Report::default();
    for _ in 0..5 {
        let mut log = |line: String| out(&line);
        let result = sync::sync_once(api, config.sync_dir()?, &mut state, options, &mut log);
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
            let dir = config.sync_dir()?.to_path_buf();
            // Cu notificari de la sistem, scanarea completa ramane doar ca plasa de siguranta.
            let watcher = match watch::Watch::new(&dir) {
                Ok(w) => Some(w),
                Err(e) => {
                    out(&format!("fara notificari de la sistem ({e}); scanez periodic"));
                    None
                }
            };
            let interval = option(&args, "--interval")
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(if watcher.is_some() { 300 } else { 10 })
                .max(1);
            out(&format!(
                "Sincronizez {} cu {}: {}.",
                dir.display(),
                config.url,
                if watcher.is_some() {
                    format!("la fiecare schimbare, si o verificare completa la {interval} secunde")
                } else {
                    format!("la fiecare {interval} secunde")
                }
            ));
            let stop_file = home.join("stop");
            let _ = std::fs::remove_file(&stop_file);
            let stop = || stop_file.exists();
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
                // Dupa o eroare (server oprit), reincercam oricum la 10 secunde.
                let max = std::time::Duration::from_secs(if last_error.is_empty() { interval } else { 10.min(interval) });
                let wake = match &watcher {
                    Some(w) => w.wait(max, &stop),
                    None => watch::sleep(max, &stop),
                };
                if wake == watch::Wake::Stop {
                    let _ = std::fs::remove_file(&stop_file);
                    out("Oprit la cerere.");
                    return Ok(());
                }
            }
        }
        "stop" => {
            if stop_running(&home)? {
                println!("Clientul de pe profilul {profile} s-a oprit.");
            } else {
                println!("Niciun client nu ruleaza pe profilul {profile}.");
            }
            Ok(())
        }
        "status" => {
            let (config, _) = load(&home)?;
            let state = state::State::load(&home.join("state.json"))?;
            println!("server:     {}", config.url);
            println!("utilizator: {}", config.user);
            match &config.dir {
                Some(dir) => println!("director:   {}", dir.display()),
                None => println!("director:   (niciunul; profil pentru disc virtual)"),
            }
            println!("cunoscute:  {} fisiere si directoare (cursor {})", state.files.len(), state.cursor);
            Ok(())
        }
        "mount" => {
            #[cfg(unix)]
            {
                let (mut config, api) = load(&home)?;
                let given = args.get(1).filter(|a| !a.starts_with("--")).map(PathBuf::from);
                let target = match given.or_else(|| config.mount_dir.clone()) {
                    Some(dir) => dir,
                    None => return Err("lipseste directorul in care sa montez (prima data: filesync-client mount DIRECTOR)".into()),
                };
                if let Some(text) = option(&args, "--cache-size") {
                    config.mount_cache_size = Some(parse_size(&text).ok_or("--cache-size: foloseste 5G, 500M...")?);
                }
                let limit = config.mount_cache_size.unwrap_or(5 << 30);
                let _guard = lock(&home)?;
                std::fs::create_dir_all(&target).map_err(|e| format!("nu pot crea {}: {e}", target.display()))?;
                // Calea absoluta, fara sa trecem prin director (ar putea fi o montare ramasa).
                let absolute = if target.is_absolute() {
                    target.clone()
                } else {
                    std::env::current_dir().map_err(|e| e.to_string())?.join(&target)
                };
                config.mount_dir = Some(absolute.clone());
                save_config(&home, &config)?;
                mount::mount(api, &home, &absolute, limit, options.host.clone(), out)
            }
            #[cfg(not(unix))]
            {
                Err("mount este pentru Linux si macOS. Pe Windows foloseste: filesync-client cloud DIRECTOR".into())
            }
        }
        "cloud" => {
            #[cfg(windows)]
            {
                let (mut config, api) = load(&home)?;
                let given = args.get(1).filter(|a| !a.starts_with("--")).map(PathBuf::from);
                let target = match given.or_else(|| config.cloud_dir.clone()) {
                    Some(dir) => dir,
                    None => return Err("lipseste directorul pentru fisierele virtuale (prima data: filesync-client cloud DIRECTOR)".into()),
                };
                if args.iter().any(|a| a == "--unregister") {
                    return cloud::unregister(&target, &config.user);
                }
                if let Some(text) = option(&args, "--cache-size") {
                    config.cloud_cache_size = Some(parse_size(&text).ok_or("--cache-size: foloseste 5G, 500M...")?);
                }
                if let Some(text) = option(&args, "--free-after") {
                    config.cloud_free_after_days =
                        Some(text.parse::<i64>().ok().filter(|d| *d >= 0).ok_or("--free-after: un numar de zile")?);
                }
                let limit = config.cloud_cache_size.unwrap_or(5 << 30);
                let free_after = config.cloud_free_after_days.unwrap_or(30) * 86_400;
                let _guard = lock(&home)?;
                // Ce s-a dat acum ramane pentru data viitoare (si pentru autostart).
                std::fs::create_dir_all(&target).map_err(|e| format!("nu pot crea {}: {e}", target.display()))?;
                config.cloud_dir = Some(target.canonicalize().map_err(|e| e.to_string())?);
                save_config(&home, &config)?;
                cloud::run(api, &home, &target, limit, options.host.clone(), &config.user, options.allow_mass_delete, free_after, out)
            }
            #[cfg(not(windows))]
            {
                Err("cloud este pentru Windows. Pe Linux si macOS foloseste: filesync-client mount DIRECTOR".into())
            }
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
