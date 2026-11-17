//! Fisiere virtuale pe Windows (Cloud Files API, mecanismul folosit de OneDrive):
//! un director este inregistrat ca "sync root", fisierele de pe server apar in el ca
//! substituenti (placeholders) care nu ocupa spatiu, iar continutul este adus de pe
//! server la prima deschidere. Varianta minima: listare, aducere la deschidere,
//! actualizari si stergeri venite de pe server. Modificarile locale nu se urca inca.

use crate::api::{Api, Entry, Fail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows_sys::Win32::Foundation::{
    ERROR_CLOUD_FILE_IN_USE, ERROR_CLOUD_FILE_NOT_IN_SYNC, ERROR_FILE_EXISTS, ERROR_SHARING_VIOLATION,
    HANDLE, STATUS_CLOUD_FILE_UNSUCCESSFUL, STATUS_SUCCESS,
};
use windows_sys::Win32::Storage::CloudFilters::*;
use windows_sys::Win32::Storage::FileSystem::{FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL, FILE_BASIC_INFO};
use windows_sys::core::GUID;

/// Identitatea furnizorului, fixa (o alegem noi o singura data).
const PROVIDER_ID: GUID = GUID {
    data1: 0x7f2a9c41,
    data2: 0x5d3e,
    data3: 0x4b8a,
    data4: [0x9e, 0x1c, 0x66, 0x51, 0x70, 0x73, 0x79, 0x6e],
};

/// Datele sunt trimise nucleului in bucati multiple de 4096 (cerinta API-ului).
const CHUNK: usize = 1 << 20;

/// Ce stim despre un substituent creat de noi.
#[derive(Serialize, Deserialize, Clone)]
struct Known {
    dir: bool,
    size: u64,
    hash: String,
    mtime: i64,
    version: i64,
}

#[derive(Serialize, Deserialize, Default)]
struct State {
    cursor: i64,
    /// Calea relativa cu "/" -> ce am creat pe disc.
    files: BTreeMap<String, Known>,
}

impl State {
    fn load(path: &Path) -> State {
        std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    fn save(&self, path: &Path) -> Result<(), String> {
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?)
            .map_err(|e| format!("nu pot scrie {}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, path).map_err(|e| format!("nu pot scrie {}: {e}", path.display()))
    }
}

struct Shared {
    api: Api,
    root: PathBuf,
    state: Mutex<State>,
    state_path: PathBuf,
    cache: PathBuf,
    cache_limit: u64,
    counter: AtomicU64,
    log: fn(&str),
}

/// Contextul pe care il primesc functiile apelate de sistem.
static SHARED: OnceLock<Arc<Shared>> = OnceLock::new();

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn wide_path(path: &Path) -> Vec<u16> {
    wide(&path.to_string_lossy())
}

/// Textul unui cod de eroare HRESULT, pentru mesaje.
fn hr_text(hr: i32) -> String {
    let code = (hr as u32) & 0xFFFF;
    let known = if hr as u32 & 0xFFFF0000 == 0x80070000 {
        match code {
            x if x == ERROR_FILE_EXISTS => "exista deja",
            x if x == ERROR_SHARING_VIOLATION => "fisierul este folosit de alt program",
            x if x == ERROR_CLOUD_FILE_IN_USE => "fisierul este folosit",
            x if x == ERROR_CLOUD_FILE_NOT_IN_SYNC => "modificat local",
            _ => "",
        }
    } else {
        ""
    };
    if known.is_empty() { format!("cod 0x{:08X}", hr as u32) } else { format!("{known} (0x{:08X})", hr as u32) }
}

fn check(hr: i32, what: &str) -> Result<(), String> {
    if hr >= 0 { Ok(()) } else { Err(format!("{what}: {}", hr_text(hr))) }
}

fn win32(hr: i32) -> Option<u32> {
    ((hr as u32) & 0xFFFF0000 == 0x80070000).then(|| (hr as u32) & 0xFFFF)
}

/// Secunde Unix -> FILETIME (intervale de 100 ns de la 1601).
fn filetime(secs: i64) -> i64 {
    secs.max(0) * 10_000_000 + 116_444_736_000_000_000
}

fn metadata(dir: bool, size: u64, mtime: i64) -> CF_FS_METADATA {
    let time = filetime(mtime);
    CF_FS_METADATA {
        BasicInfo: FILE_BASIC_INFO {
            CreationTime: time,
            LastAccessTime: time,
            LastWriteTime: time,
            ChangeTime: time,
            FileAttributes: if dir { FILE_ATTRIBUTE_DIRECTORY } else { FILE_ATTRIBUTE_NORMAL },
        },
        FileSize: if dir { 0 } else { size as i64 },
    }
}

fn parent_of(path: &str) -> &str {
    path.rfind('/').map(|i| &path[..i]).unwrap_or("")
}

fn name_of(path: &str) -> &str {
    path.rfind('/').map(|i| &path[i + 1..]).unwrap_or(path)
}

impl Shared {
    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Calea de pe disc a unei cai relative de pe server.
    fn local(&self, path: &str) -> PathBuf {
        let mut full = self.root.clone();
        for part in path.split('/').filter(|p| !p.is_empty()) {
            full.push(part);
        }
        full
    }

    /// Creeaza un substituent pentru o intrare de pe server.
    fn create(&self, entry: &Entry) -> Result<(), String> {
        let base = wide_path(&self.local(parent_of(&entry.path)));
        let name = wide(name_of(&entry.path));
        let identity = entry.path.as_bytes();
        let mut flags = CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC;
        if entry.dir {
            flags |= CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION;
        }
        let mut info = CF_PLACEHOLDER_CREATE_INFO {
            RelativeFileName: name.as_ptr(),
            FsMetadata: metadata(entry.dir, entry.size, entry.mtime),
            FileIdentity: identity.as_ptr().cast(),
            FileIdentityLength: identity.len() as u32,
            Flags: flags,
            Result: 0,
            CreateUsn: 0,
        };
        let mut processed = 0u32;
        // SAFETY: toate adresele date arata spre valori care traiesc pe durata apelului.
        let hr = unsafe { CfCreatePlaceholders(base.as_ptr(), &mut info, 1, CF_CREATE_FLAG_NONE, &mut processed) };
        // Exista deja (de la o rulare anterioara): este in regula.
        let exists = win32(hr) == Some(ERROR_FILE_EXISTS) || win32(info.Result) == Some(ERROR_FILE_EXISTS);
        if exists {
            return Ok(());
        }
        check(hr, "creare substituent")?;
        if info.Result < 0 {
            return Err(format!("creare substituent: {}", hr_text(info.Result)));
        }
        Ok(())
    }

    /// Fisierul s-a schimbat pe server: substituentul este golit si primeste noile date.
    /// Daca are modificari locale neurcate, este lasat in pace (si se spune).
    fn update(&self, entry: &Entry) -> Result<(), String> {
        let path = wide_path(&self.local(&entry.path));
        let mut handle: HANDLE = std::ptr::null_mut();
        // SAFETY: `path` este un sir UTF-16 terminat cu zero; `handle` primeste rezultatul.
        let hr = unsafe {
            CfOpenFileWithOplock(path.as_ptr(), CF_OPEN_FILE_FLAG_WRITE_ACCESS | CF_OPEN_FILE_FLAG_EXCLUSIVE, &mut handle)
        };
        check(hr, "deschidere")?;
        let meta = metadata(false, entry.size, entry.mtime);
        let identity = entry.path.as_bytes();
        let flags = CF_UPDATE_FLAG_DEHYDRATE | CF_UPDATE_FLAG_MARK_IN_SYNC | CF_UPDATE_FLAG_VERIFY_IN_SYNC;
        // SAFETY: handle-ul este valid (abia deschis); adresele traiesc pe durata apelului.
        let hr = unsafe {
            CfUpdatePlaceholder(
                handle,
                &meta,
                identity.as_ptr().cast(),
                identity.len() as u32,
                std::ptr::null(),
                0,
                flags,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        // SAFETY: inchidem handle-ul primit de la CfOpenFileWithOplock, o singura data.
        unsafe { CfCloseHandle(handle) };
        check(hr, "actualizare substituent")
    }

    /// Aduce in disc ce s-a schimbat pe server.
    fn refresh(&self) -> Result<usize, Fail> {
        let cursor = self.state().cursor;
        let (entries, new_cursor) = self.api.changes(cursor)?;
        let mut changed = 0;
        // Stergerile: intai copiii, apoi parintii. Restul: intai parintii.
        let (mut deleted, mut live): (Vec<Entry>, Vec<Entry>) = entries.into_iter().partition(|e| e.deleted);
        deleted.sort_by(|a, b| b.path.cmp(&a.path));
        live.sort_by(|a, b| a.path.cmp(&b.path));
        for entry in deleted {
            let known = self.state().files.get(&entry.path).cloned();
            let Some(known) = known else { continue };
            let local = self.local(&entry.path);
            let result = if known.dir { std::fs::remove_dir(&local) } else { std::fs::remove_file(&local) };
            match result {
                Ok(()) => (self.log)(&format!("sters     {}", entry.path)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => {
                    (self.log)(&format!("EROARE    {}: nu pot sterge local: {e}", entry.path));
                    continue;
                }
            }
            self.state().files.remove(&entry.path);
            changed += 1;
        }
        for entry in live {
            let known = self.state().files.get(&entry.path).cloned();
            let result = match known {
                Some(k) if k.dir && entry.dir => Ok(()),
                Some(k) if !k.dir && !entry.dir && k.version == entry.version => Ok(()),
                Some(k) if !k.dir && !entry.dir => {
                    let r = self.update(&entry);
                    if r.is_ok() {
                        (self.log)(&format!("innoit    {}", entry.path));
                    }
                    r
                }
                Some(k) => {
                    // Si-a schimbat felul (fisier <-> director): il facem din nou.
                    let local = self.local(&entry.path);
                    let _ = if k.dir { std::fs::remove_dir_all(&local) } else { std::fs::remove_file(&local) };
                    self.create(&entry)
                }
                None => {
                    let r = self.create(&entry);
                    if r.is_ok() {
                        (self.log)(&format!("aparut    {}", entry.path));
                    }
                    r
                }
            };
            match result {
                Ok(()) => {
                    self.state().files.insert(
                        entry.path.clone(),
                        Known { dir: entry.dir, size: entry.size, hash: entry.hash, mtime: entry.mtime, version: entry.version },
                    );
                    changed += 1;
                }
                Err(e) => (self.log)(&format!("EROARE    {}: {e}", entry.path)),
            }
        }
        {
            let mut state = self.state();
            state.cursor = new_cursor;
            if let Err(e) = state.save(&self.state_path) {
                (self.log)(&format!("EROARE    {e}"));
            }
        }
        Ok(changed)
    }

    fn temp(&self) -> PathBuf {
        let n = self.counter.fetch_add(1, Ordering::Relaxed);
        self.cache.join(format!(".part-{}-{n}", std::process::id()))
    }

    /// Continutul unui fisier, din cache sau adus de pe server.
    fn cached(&self, path: &str, known: &Known) -> Result<PathBuf, String> {
        let target = self.cache.join(&known.hash);
        if target.exists() {
            if let Ok(file) = File::options().write(true).open(&target) {
                let _ = file.set_modified(SystemTime::now());
            }
            return Ok(target);
        }
        let tmp = self.temp();
        match self.api.download(path, &tmp) {
            Ok(hash) if hash == known.hash => {}
            Ok(_) => {
                let _ = std::fs::remove_file(&tmp);
                return Err("s-a schimbat pe server intre timp; mai incearca".into());
            }
            Err(e) => {
                let _ = std::fs::remove_file(&tmp);
                return Err(e.to_string());
            }
        }
        if !target.exists() {
            std::fs::rename(&tmp, &target).map_err(|e| e.to_string())?;
        } else {
            let _ = std::fs::remove_file(&tmp);
        }
        self.evict(&target);
        Ok(target)
    }

    /// Tine cache-ul sub limita, stergand ce nu a mai fost folosit de cel mai mult timp.
    fn evict(&self, keep: &Path) {
        let Ok(entries) = std::fs::read_dir(&self.cache) else { return };
        let mut files: Vec<(SystemTime, u64, PathBuf)> = entries
            .flatten()
            .filter_map(|e| {
                let meta = e.metadata().ok()?;
                (meta.is_file() && e.path() != keep).then(|| (meta.modified().unwrap_or(UNIX_EPOCH), meta.len(), e.path()))
            })
            .collect();
        let kept = std::fs::metadata(keep).map(|m| m.len()).unwrap_or(0);
        let mut total: u64 = kept + files.iter().map(|f| f.1).sum::<u64>();
        files.sort();
        for (_, size, path) in files {
            if total <= self.cache_limit {
                break;
            }
            if std::fs::remove_file(&path).is_ok() {
                total -= size;
            }
        }
    }

    /// Trimite nucleului continutul cerut (sau o eroare, cu `data` None).
    fn transfer(&self, request: &Fetch, data: Option<&Path>) {
        let info = CF_OPERATION_INFO {
            StructSize: std::mem::size_of::<CF_OPERATION_INFO>() as u32,
            Type: CF_OPERATION_TYPE_TRANSFER_DATA,
            ConnectionKey: request.connection,
            TransferKey: request.transfer,
            CorrelationVector: std::ptr::null(),
            SyncStatus: std::ptr::null(),
            RequestKey: request.request,
        };
        let param_size = (std::mem::offset_of!(CF_OPERATION_PARAMETERS, Anonymous)
            + std::mem::size_of::<CF_OPERATION_PARAMETERS_0_0>()) as u32;
        let send = |buffer: &[u8], offset: i64, status: i32| -> i32 {
            let mut params = CF_OPERATION_PARAMETERS {
                ParamSize: param_size,
                Anonymous: CF_OPERATION_PARAMETERS_0 {
                    TransferData: CF_OPERATION_PARAMETERS_0_0 {
                        Flags: CF_OPERATION_TRANSFER_DATA_FLAG_NONE,
                        CompletionStatus: status,
                        Buffer: buffer.as_ptr().cast(),
                        Offset: offset,
                        Length: buffer.len() as i64,
                    },
                },
            };
            // SAFETY: structurile sunt completate dupa documentatie si traiesc pe durata apelului.
            unsafe { CfExecute(&info, &mut params) }
        };
        let Some(path) = data else {
            let hr = send(&[], 0, STATUS_CLOUD_FILE_UNSUCCESSFUL);
            if hr < 0 {
                (self.log)(&format!("EROARE    {}: nu pot raporta esecul: {}", request.path, hr_text(hr)));
            }
            return;
        };
        let result = (|| -> Result<(), String> {
            let mut file = File::open(path).map_err(|e| e.to_string())?;
            let total = file.metadata().map_err(|e| e.to_string())?.len();
            let mut buffer = vec![0u8; CHUNK];
            let mut offset: u64 = 0;
            while offset < total {
                let want = ((total - offset) as usize).min(CHUNK);
                let mut filled = 0;
                while filled < want {
                    let n = file.read(&mut buffer[filled..want]).map_err(|e| e.to_string())?;
                    if n == 0 {
                        return Err("fisierul din cache este mai scurt decat anuntat".into());
                    }
                    filled += n;
                }
                let hr = send(&buffer[..filled], offset as i64, STATUS_SUCCESS);
                check(hr, "transfer")?;
                offset += filled as u64;
                // SAFETY: cheile sunt cele primite in cerere; apelul doar raporteaza progresul.
                unsafe {
                    CfReportProviderProgress(request.connection, request.transfer, total as i64, offset as i64);
                }
            }
            if total == 0 {
                check(send(&[], 0, STATUS_SUCCESS), "transfer")?;
            }
            Ok(())
        })();
        match result {
            Ok(()) => (self.log)(&format!("adus      {}", request.path)),
            Err(e) => {
                (self.log)(&format!("EROARE    {}: {e}", request.path));
                let _ = send(&[], 0, STATUS_CLOUD_FILE_UNSUCCESSFUL);
            }
        }
    }

    /// O cerere de continut, servita intr-un fir separat ca sa nu tina sistemul in loc.
    fn fetch(self: &Arc<Self>, request: Fetch) {
        let shared = self.clone();
        std::thread::spawn(move || {
            let known = shared.state().files.get(&request.path).cloned();
            let Some(known) = known else {
                (shared.log)(&format!("EROARE    {}: fisier necunoscut", request.path));
                shared.transfer(&request, None);
                return;
            };
            match shared.cached(&request.path, &known) {
                Ok(path) => shared.transfer(&request, Some(&path)),
                Err(e) => {
                    (shared.log)(&format!("EROARE    {}: {e}", request.path));
                    shared.transfer(&request, None);
                }
            }
        });
    }
}

/// Ce ne cere sistemul cand un program deschide un substituent fara continut.
struct Fetch {
    path: String,
    connection: CF_CONNECTION_KEY,
    transfer: i64,
    request: i64,
}

/// Apelata de sistem (pe un fir al lui) cand trebuie adus continutul unui fisier.
unsafe extern "system" fn on_fetch_data(info: *const CF_CALLBACK_INFO, _params: *const CF_CALLBACK_PARAMETERS) {
    let Some(shared) = SHARED.get() else { return };
    // SAFETY: sistemul garanteaza ca `info` si identitatea fisierului sunt valide pe durata apelului.
    let (path, connection, transfer, request) = unsafe {
        let info = &*info;
        let identity = std::slice::from_raw_parts(info.FileIdentity.cast::<u8>(), info.FileIdentityLength as usize);
        (String::from_utf8_lossy(identity).into_owned(), info.ConnectionKey, info.TransferKey, info.RequestKey)
    };
    shared.fetch(Fetch { path, connection, transfer, request });
}

unsafe extern "system" fn on_cancel_fetch_data(info: *const CF_CALLBACK_INFO, _params: *const CF_CALLBACK_PARAMETERS) {
    let Some(shared) = SHARED.get() else { return };
    // SAFETY: ca mai sus.
    let path = unsafe {
        let info = &*info;
        let identity = std::slice::from_raw_parts(info.FileIdentity.cast::<u8>(), info.FileIdentityLength as usize);
        String::from_utf8_lossy(identity).into_owned()
    };
    (shared.log)(&format!("anulat    {} (descarcarea continua in fundal)", path));
}

fn register(root: &Path) -> Result<(), String> {
    let name = wide("filesync");
    let version = wide(env!("CARGO_PKG_VERSION"));
    let registration = CF_SYNC_REGISTRATION {
        StructSize: std::mem::size_of::<CF_SYNC_REGISTRATION>() as u32,
        ProviderName: name.as_ptr(),
        ProviderVersion: version.as_ptr(),
        SyncRootIdentity: std::ptr::null(),
        SyncRootIdentityLength: 0,
        FileIdentity: std::ptr::null(),
        FileIdentityLength: 0,
        ProviderId: PROVIDER_ID,
    };
    let policies = CF_SYNC_POLICIES {
        StructSize: std::mem::size_of::<CF_SYNC_POLICIES>() as u32,
        Hydration: CF_HYDRATION_POLICY { Primary: CF_HYDRATION_POLICY_FULL, Modifier: CF_HYDRATION_POLICY_MODIFIER_NONE },
        Population: CF_POPULATION_POLICY {
            Primary: CF_POPULATION_POLICY_ALWAYS_FULL,
            Modifier: CF_POPULATION_POLICY_MODIFIER_NONE,
        },
        InSync: CF_INSYNC_POLICY_TRACK_ALL,
        HardLink: CF_HARDLINK_POLICY_NONE,
        PlaceholderManagement: CF_PLACEHOLDER_MANAGEMENT_POLICY_DEFAULT,
    };
    let path = wide_path(root);
    let flags = CF_REGISTER_FLAG_DISABLE_ON_DEMAND_POPULATION_ON_ROOT | CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT;
    // SAFETY: toate adresele arata spre valori care traiesc pe durata apelului.
    let mut hr = unsafe { CfRegisterSyncRoot(path.as_ptr(), &registration, &policies, flags) };
    if hr < 0 {
        // Era deja inregistrat (de o rulare anterioara): doar actualizam inregistrarea.
        // SAFETY: ca mai sus.
        hr = unsafe { CfRegisterSyncRoot(path.as_ptr(), &registration, &policies, flags | CF_REGISTER_FLAG_UPDATE) };
    }
    check(hr, &format!("nu pot inregistra {} ca director de fisiere virtuale", root.display()))
}

/// Scoate inregistrarea. Substituentii ramasi fara continut nu mai pot fi deschisi,
/// deci directorul trebuie sters dupa aceea.
pub fn unregister(target: &Path) -> Result<(), String> {
    let root = target.canonicalize().map_err(|e| format!("{}: {e}", target.display()))?;
    let path = wide_path(&root);
    // SAFETY: `path` este un sir UTF-16 terminat cu zero.
    let hr = unsafe { CfUnregisterSyncRoot(path.as_ptr()) };
    check(hr, &format!("nu pot scoate inregistrarea pentru {}", root.display()))?;
    println!("Inregistrarea pentru {} a fost scoasa. Fisierele fara continut nu mai pot fi deschise;", root.display());
    println!("poti sterge directorul.");
    Ok(())
}

/// Porneste fisierele virtuale si ramane pornit pana la Ctrl+C.
pub fn run(api: Api, home: &Path, target: &Path, cache_limit: u64, log: fn(&str)) -> Result<(), String> {
    let mut platform = CF_PLATFORM_INFO { BuildNumber: 0, RevisionNumber: 0, IntegrationNumber: 0 };
    // SAFETY: `platform` primeste rezultatul.
    if unsafe { CfGetPlatformInfo(&mut platform) } < 0 {
        return Err("acest Windows nu are Cloud Files API (este nevoie de Windows 10 1709 sau mai nou)".into());
    }
    std::fs::create_dir_all(target).map_err(|e| format!("nu pot crea {}: {e}", target.display()))?;
    let root = target.canonicalize().map_err(|e| e.to_string())?;
    // canonicalize da o cale \\?\C:\...; API-ul vrea forma obisnuita.
    let root = PathBuf::from(root.to_string_lossy().trim_start_matches(r"\\?\").to_string());
    let cache = home.join("cache");
    std::fs::create_dir_all(&cache).map_err(|e| format!("nu pot crea {}: {e}", cache.display()))?;
    if let Ok(entries) = std::fs::read_dir(&cache) {
        for entry in entries.flatten() {
            if entry.file_name().to_string_lossy().starts_with(".part-") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    let state_path = home.join("cloud.json");
    let state = State::load(&state_path);

    register(&root)?;
    let shared = Arc::new(Shared {
        api,
        root: root.clone(),
        state: Mutex::new(state),
        state_path,
        cache,
        cache_limit,
        counter: AtomicU64::new(0),
        log,
    });
    SHARED.set(shared.clone()).map_err(|_| "pornit de doua ori".to_string())?;

    let callbacks = [
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_FETCH_DATA, Callback: Some(on_fetch_data) },
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, Callback: Some(on_cancel_fetch_data) },
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_NONE, Callback: None },
    ];
    let path = wide_path(&root);
    let mut connection: CF_CONNECTION_KEY = 0;
    // SAFETY: tabelul se incheie cu CF_CALLBACK_TYPE_NONE; `connection` primeste cheia.
    let hr = unsafe { CfConnectSyncRoot(path.as_ptr(), callbacks.as_ptr(), std::ptr::null(), CF_CONNECT_FLAG_NONE, &mut connection) };
    check(hr, &format!("nu ma pot lega de {}", root.display()))?;

    match shared.refresh() {
        Ok(n) => log(&format!("Fisiere virtuale in {} ({n} schimbari la pornire). Ctrl+C opreste.", root.display())),
        Err(e) => log(&format!("Fisiere virtuale in {}; serverul nu raspunde acum ({e}). Ctrl+C opreste.", root.display())),
    }

    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    ctrlc::set_handler(move || flag.store(true, Ordering::SeqCst)).map_err(|e| e.to_string())?;
    let mut last = Instant::now();
    let mut down = false;
    while !stop.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(300));
        if last.elapsed() >= Duration::from_secs(10) {
            match shared.refresh() {
                Ok(_) => {
                    if down {
                        log("serverul raspunde din nou");
                        down = false;
                    }
                }
                Err(e) => {
                    if !down {
                        log(&format!("serverul nu raspunde ({e}); reincerc periodic"));
                        down = true;
                    }
                }
            }
            last = Instant::now();
        }
    }
    // SAFETY: cheia este cea primita la legare.
    let hr = unsafe { CfDisconnectSyncRoot(connection) };
    check(hr, "dezlegare")?;
    log("Oprit. Fisierele raman in director; cele neaduse se aduc la urmatoarea pornire.");
    Ok(())
}
