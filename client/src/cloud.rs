//! Fisiere virtuale pe Windows (Cloud Files API, mecanismul folosit de OneDrive):
//! un director este inregistrat ca "sync root", fisierele de pe server apar in el ca
//! substituenti (placeholders) care nu ocupa spatiu, iar continutul este adus de pe
//! server la prima deschidere.
//!
//! Dinspre server: substituenti noi, versiuni noi (substituentul este golit si adus din nou
//! la deschidere), stergeri. Dinspre Windows: la fiecare cateva secunde directorul este
//! comparat cu ce stie clientul; fisierele noi sau modificate sunt urcate (si transformate
//! in substituenti), cele disparute sunt sterse de pe server, cele mutate sunt mutate.
//! Un fisier schimbat in ambele parti: versiunea de pe server ramane sub numele original,
//! cea locala este urcata ca "nume (conflict data calculator).ext".
//! Spatiul: un fisier adus si nedeschis de un timp (`--free-after`) este golit din nou.

use crate::api::{Api, Entry, Fail};
use crate::scan::{self, Local};
use crate::sync::{date, now};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows_sys::Win32::Foundation::{
    ERROR_CLOUD_FILE_IN_USE, ERROR_CLOUD_FILE_NOT_IN_SYNC, ERROR_FILE_EXISTS, ERROR_FILE_NOT_FOUND,
    ERROR_SHARING_VIOLATION, HANDLE, STATUS_CLOUD_FILE_UNSUCCESSFUL, STATUS_SUCCESS,
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
    /// Cand a fost deschis ultima data (secunde Unix); 0 = nu are continut local.
    #[serde(default)]
    opened: i64,
}

#[derive(Serialize, Deserialize, Default)]
struct State {
    cursor: i64,
    /// Calea relativa cu "/" -> ce am creat pe disc.
    files: BTreeMap<String, Known>,
    /// Schimbari de pe server care nu au putut fi aplicate inca (fisier modificat local
    /// sau folosit de un program); se reincearca la fiecare trecere.
    #[serde(default)]
    held: BTreeMap<String, Entry>,
    /// Identitatea veche a substituentilor mutati -> calea de acum (cererile de continut
    /// vin cu identitatea de la creare).
    #[serde(default)]
    aliases: BTreeMap<String, String>,
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
    host: String,
    allow_mass_delete: bool,
    /// Dupa cate secunde fara deschidere un fisier adus este golit; 0 = niciodata.
    free_after: i64,
    /// Lucruri deja anuntate ca amanate, ca sa nu le repetam la fiecare trecere.
    quiet: Mutex<HashSet<String>>,
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
            x if x == ERROR_FILE_NOT_FOUND => "nu exista local",
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
    // Serverul nu tine data directoarelor; aratam momentul in care le-am aflat.
    let time = filetime(if dir && mtime == 0 { now() } else { mtime });
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

    /// Deschide un fisier din director cu un handle potrivit pentru API-ul Cloud Files.
    fn open(&self, path: &str, flags: CF_OPEN_FILE_FLAGS) -> Result<Opened, String> {
        let wide = wide_path(&self.local(path));
        let mut handle: HANDLE = std::ptr::null_mut();
        // SAFETY: `wide` este un sir UTF-16 terminat cu zero; `handle` primeste rezultatul.
        let hr = unsafe { CfOpenFileWithOplock(wide.as_ptr(), flags, &mut handle) };
        check(hr, "deschidere")?;
        Ok(Opened(handle))
    }

    /// Fisierul s-a schimbat pe server: substituentul este golit si primeste noile date.
    /// Fara `force`, un fisier cu modificari locale neurcate este lasat in pace.
    fn update(&self, entry: &Entry, force: bool) -> Result<(), String> {
        let opened = self.open(&entry.path, CF_OPEN_FILE_FLAG_WRITE_ACCESS | CF_OPEN_FILE_FLAG_EXCLUSIVE)?;
        let meta = metadata(false, entry.size, entry.mtime);
        let identity = entry.path.as_bytes();
        let mut flags = CF_UPDATE_FLAG_DEHYDRATE | CF_UPDATE_FLAG_MARK_IN_SYNC;
        if !force {
            flags |= CF_UPDATE_FLAG_VERIFY_IN_SYNC;
        }
        // SAFETY: handle-ul este valid; adresele traiesc pe durata apelului.
        let hr = unsafe {
            CfUpdatePlaceholder(
                opened.0,
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
        check(hr, "actualizare substituent")
    }

    /// Un fisier obisnuit, abia urcat, devine substituent (cu continutul pastrat local).
    /// Daca era deja substituent (de exemplu mutat), doar identitatea si starea sunt innoite.
    fn mark_synced(&self, path: &str) -> Result<(), String> {
        let opened = self.open(path, CF_OPEN_FILE_FLAG_WRITE_ACCESS | CF_OPEN_FILE_FLAG_EXCLUSIVE)?;
        let identity = path.as_bytes();
        // SAFETY: handle valid; adresele traiesc pe durata apelului.
        let hr = unsafe {
            CfConvertToPlaceholder(
                opened.0,
                identity.as_ptr().cast(),
                identity.len() as u32,
                CF_CONVERT_FLAG_MARK_IN_SYNC,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if hr >= 0 {
            return Ok(());
        }
        // SAFETY: ca mai sus.
        let hr = unsafe {
            CfUpdatePlaceholder(
                opened.0,
                std::ptr::null(),
                identity.as_ptr().cast(),
                identity.len() as u32,
                std::ptr::null(),
                0,
                CF_UPDATE_FLAG_MARK_IN_SYNC,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        check(hr, "marcare ca sincronizat")
    }

    /// Identitatea unui substituent (calea de la creare); None pentru un fisier obisnuit.
    fn identity(&self, path: &str) -> Option<String> {
        let opened = self.open(path, CF_OPEN_FILE_FLAG_NONE).ok()?;
        let mut buffer = vec![0u8; std::mem::size_of::<CF_PLACEHOLDER_BASIC_INFO>() + 4096];
        let mut returned = 0u32;
        // SAFETY: tamponul are loc pentru structura si pentru o identitate de cel mult 4 KB.
        let hr = unsafe {
            CfGetPlaceholderInfo(
                opened.0,
                CF_PLACEHOLDER_INFO_BASIC,
                buffer.as_mut_ptr().cast(),
                buffer.len() as u32,
                &mut returned,
            )
        };
        if hr < 0 {
            return None;
        }
        // SAFETY: structura a fost scrisa de API la inceputul tamponului.
        let info = unsafe { &*(buffer.as_ptr() as *const CF_PLACEHOLDER_BASIC_INFO) };
        let start = std::mem::offset_of!(CF_PLACEHOLDER_BASIC_INFO, FileIdentity);
        let end = start + info.FileIdentityLength as usize;
        buffer.get(start..end).map(|b| String::from_utf8_lossy(b).into_owned())
    }

    /// Aplica o schimbare venita de pe server pentru un fisier pe care il stim deja.
    fn apply_update(&self, entry: &Entry, force: bool) -> Result<(), String> {
        let r = self.update(entry, force);
        if r.is_ok() {
            (self.log)(&format!("innoit    {}", entry.path));
        }
        r
    }

    fn record(&self, entry: &Entry) {
        let mut state = self.state();
        state.held.remove(&entry.path);
        state.files.insert(
            entry.path.clone(),
            Known {
                dir: entry.dir,
                size: entry.size,
                hash: entry.hash.clone(),
                mtime: entry.mtime,
                version: entry.version,
                opened: 0,
            },
        );
    }

    fn save(&self) {
        let state = self.state();
        if let Err(e) = state.save(&self.state_path) {
            (self.log)(&format!("EROARE    {e}"));
        }
    }

    /// Aduce in disc ce s-a schimbat pe server (si ce a ramas neaplicat data trecuta).
    fn refresh(&self) -> Result<usize, Fail> {
        let cursor = self.state().cursor;
        let (entries, new_cursor) = self.api.changes(cursor)?;
        let mut changed = 0;
        // Stergerile: intai copiii, apoi parintii. Restul: intai parintii.
        let (mut deleted, mut live): (Vec<Entry>, Vec<Entry>) = entries.into_iter().partition(|e| e.deleted);
        deleted.sort_by(|a, b| b.path.cmp(&a.path));
        live.sort_by(|a, b| a.path.cmp(&b.path));
        for entry in deleted {
            self.state().held.remove(&entry.path);
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
        // Ce a ramas neaplicat data trecuta se incearca din nou, inaintea noutatilor.
        let held: Vec<Entry> = self.state().held.values().cloned().collect();
        for entry in held.into_iter().chain(live) {
            let known = self.state().files.get(&entry.path).cloned();
            let result = match known {
                Some(k) if k.dir && entry.dir => Ok(()),
                Some(k) if !k.dir && !entry.dir && k.version == entry.version => Ok(()),
                Some(k) if !k.dir && !entry.dir => self.apply_update(&entry, k.version == -1),
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
                    self.record(&entry);
                    changed += 1;
                }
                Err(e) => {
                    let mut state = self.state();
                    if !state.held.contains_key(&entry.path) {
                        (self.log)(&format!("amanat    {}: {e}", entry.path));
                    }
                    state.held.insert(entry.path.clone(), entry);
                }
            }
        }
        self.state().cursor = new_cursor;
        self.save();
        Ok(changed)
    }

    /// Directoarele create de versiunile vechi au data 1970 (serverul nu tine data lor):
    /// primesc data de acum.
    fn fix_dir_dates(&self) {
        let dirs: Vec<String> = self.state().files.iter().filter(|(_, k)| k.dir).map(|(p, _)| p.clone()).collect();
        for path in dirs {
            let old = std::fs::metadata(self.local(&path))
                .ok()
                .map(|m| scan::mtime_of(&m))
                .is_some_and(|secs| secs < 365 * 86_400);
            if !old {
                continue;
            }
            let Ok(opened) = self.open(&path, CF_OPEN_FILE_FLAG_WRITE_ACCESS) else { continue };
            let meta = metadata(true, 0, 0);
            // SAFETY: handle valid; metadatele traiesc pe durata apelului.
            unsafe {
                CfUpdatePlaceholder(
                    opened.0,
                    &meta,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    CF_UPDATE_FLAG_NONE,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                );
            }
        }
    }

    /// Tine minte ca un fisier a fost deschis (sau tocmai a primit continut).
    fn touched(&self, identity: &str) {
        let mut state = self.state();
        let path = state.aliases.get(identity).cloned().unwrap_or_else(|| identity.to_string());
        if let Some(k) = state.files.get_mut(&path) {
            k.opened = now();
        }
    }

    /// Goleste fisierele aduse si nedeschise de mai mult de `free_after` secunde.
    fn free_space(&self) {
        if self.free_after <= 0 {
            return;
        }
        let limit = now() - self.free_after;
        let candidates: Vec<(String, Known)> = self
            .state()
            .files
            .iter()
            .filter(|(_, k)| !k.dir && k.version > 0 && k.opened > 0 && k.opened < limit)
            .map(|(p, k)| (p.clone(), k.clone()))
            .collect();
        let mut freed = 0;
        for (path, k) in candidates {
            // Un fisier modificat local nu se goleste: intai trebuie urcat.
            let Some(local) = scan::stat(&self.local(&path)) else { continue };
            if local.dir || local.size != k.size || local.mtime != k.mtime {
                continue;
            }
            let Ok(opened) = self.open(&path, CF_OPEN_FILE_FLAG_WRITE_ACCESS | CF_OPEN_FILE_FLAG_EXCLUSIVE) else {
                continue; // este folosit de un program; alta data
            };
            // SAFETY: handle valid; lungimea -1 inseamna pana la sfarsit.
            let hr = unsafe { CfDehydratePlaceholder(opened.0, 0, -1, CF_DEHYDRATE_FLAG_NONE, std::ptr::null_mut()) };
            if hr >= 0 {
                if let Some(k) = self.state().files.get_mut(&path) {
                    k.opened = 0;
                }
                freed += 1;
            }
        }
        if freed > 0 {
            let age = if self.free_after >= 86_400 {
                format!("{} zile", self.free_after / 86_400)
            } else {
                format!("{} secunde", self.free_after)
            };
            (self.log)(&format!("eliberat  {freed} fisiere nedeschise de {age} (raman vizibile)"));
            self.save();
        }
    }

    /// Spune o data ca un lucru este amanat; a doua oara tace.
    fn later(&self, path: &str, why: &str) {
        if self.quiet.lock().unwrap_or_else(|e| e.into_inner()).insert(path.to_string()) {
            (self.log)(&format!("amanat    {path} ({why})"));
        }
    }

    fn done(&self, path: &str) {
        self.quiet.lock().unwrap_or_else(|e| e.into_inner()).remove(path);
    }

    /// Urca pe server ce s-a schimbat in director: fisiere noi sau modificate, stergeri, mutari.
    fn push(&self) {
        let found = match scan::scan(&self.root) {
            Ok(found) => found,
            Err(e) => {
                (self.log)(&format!("EROARE    nu pot citi {}: {e}", self.root.display()));
                return;
            }
        };
        let mut changed = false;

        // 1. Mutari: un substituent necunoscut la calea de acum, a carui identitate este o cale
        //    pe care o stim si care nu mai exista pe disc. (Un director mutat este tratat
        //    primul, iar copiii lui ajung astfel cunoscuti sub noile cai.)
        for path in found.keys() {
            if self.state().files.contains_key(path) {
                continue;
            }
            let Some(old) = self.identity(path) else { continue };
            if old == *path || found.contains_key(&old) || !self.state().files.contains_key(&old) {
                continue;
            }
            match self.api.rename(&old, path) {
                Ok(()) => {
                    (self.log)(&format!("mutat     {old} -> {path}"));
                    let mut state = self.state();
                    let moved: Vec<String> = state
                        .files
                        .keys()
                        .filter(|k| *k == &old || k.starts_with(&format!("{old}/")))
                        .cloned()
                        .collect();
                    for from in moved {
                        let to = format!("{path}{}", &from[old.len()..]);
                        if let Some(mut k) = state.files.remove(&from) {
                            // Versiunile de la noua cale se afla de pe server.
                            if !k.dir {
                                k.version = -1;
                            }
                            state.files.insert(to.clone(), k);
                        }
                        state.held.remove(&from);
                        state.aliases.insert(from, to);
                    }
                    changed = true;
                }
                Err(e) => (self.log)(&format!("EROARE    {old} -> {path}: {e}")),
            }
        }
        let known: BTreeMap<String, Known> = self.state().files.clone();

        // 2. Fisiere noi si modificate, de sus in jos.
        let settle = now() - 2;
        for (path, local) in &found {
            match known.get(path) {
                Some(k) if k.dir && local.dir => {}
                Some(k) if !k.dir && !local.dir && k.size == local.size && k.mtime == local.mtime => {}
                Some(k) if !k.dir && !local.dir => {
                    if local.mtime > settle {
                        self.later(path, "inca se scrie");
                        continue;
                    }
                    if k.version < 0 {
                        self.later(path, "abia mutat; astept versiunea de pe server");
                        continue;
                    }
                    if self.upload(path, local, k.version) {
                        changed = true;
                    }
                }
                Some(_) => {
                    // Fisier devenit director sau invers: serverul afla la trecerea urmatoare,
                    // dupa ce stergerea vechiului nume a fost trimisa.
                }
                None if local.dir => match self.api.mkdir(path) {
                    Ok(()) => {
                        (self.log)(&format!("creat     {path}/"));
                        let _ = self.mark_synced(path);
                        self.state().files.insert(
                            path.clone(),
                            Known { dir: true, size: 0, hash: String::new(), mtime: 0, version: 0, opened: 0 },
                        );
                        changed = true;
                    }
                    Err(e) => (self.log)(&format!("EROARE    {path}: {e}")),
                },
                None => {
                    if local.mtime > settle {
                        self.later(path, "inca se scrie");
                        continue;
                    }
                    if self.upload(path, local, 0) {
                        changed = true;
                    }
                }
            }
        }

        // 3. Stergeri, de jos in sus, cu protectie la stergerile in masa.
        let missing: Vec<(String, Known)> = known
            .iter()
            .filter(|(p, _)| !found.contains_key(*p))
            .map(|(p, k)| (p.clone(), k.clone()))
            .rev()
            .collect();
        if missing.len() > 50 && missing.len() * 2 > known.len() && !self.allow_mass_delete {
            self.later(
                "",
                &format!(
                    "{} din {} fisiere si directoare lipsesc local si ar fi sterse de pe server; \
                     daca le-ai sters intentionat, porneste din nou cu --allow-mass-delete",
                    missing.len(),
                    known.len()
                ),
            );
        } else {
            for (path, k) in missing {
                match self.api.delete(&path, None) {
                    Ok(()) => {
                        (self.log)(&format!("sters     {path} (de pe server)"));
                        let mut state = self.state();
                        state.files.remove(&path);
                        state.held.remove(&path);
                        changed = true;
                    }
                    Err(Fail::Refused(m)) if m.starts_with("409") && k.dir => {
                        self.later(&path, "directorul nu este gol pe server");
                    }
                    Err(e) => (self.log)(&format!("EROARE    {path}: {e}")),
                }
            }
        }
        if changed {
            self.save();
        }
    }

    /// Urca un fisier local. Intoarce true daca s-a schimbat ceva de tinut minte.
    fn upload(&self, path: &str, local: &Local, if_version: i64) -> bool {
        let file = self.local(path);
        match self.api.upload(path, &file, local.size, local.mtime, if_version) {
            Ok((version, hash)) => {
                (self.log)(&format!("urcat     {path}"));
                if let Err(e) = self.mark_synced(path) {
                    (self.log)(&format!("EROARE    {path}: {e}"));
                }
                self.done(path);
                let mut state = self.state();
                state.held.remove(path);
                state.files.insert(
                    path.to_string(),
                    Known { dir: false, size: local.size, hash, mtime: local.mtime, version, opened: now() },
                );
                true
            }
            Err(Fail::Conflict) => self.conflict(path, local),
            Err(e) => {
                (self.log)(&format!("EROARE    {path}: {e}"));
                false
            }
        }
    }

    /// Fisierul s-a schimbat si pe server: versiunea locala este urcata sub alt nume,
    /// iar sub numele original este adusa versiunea de pe server.
    fn conflict(&self, path: &str, local: &Local) -> bool {
        // Schimbarea de pe server trebuie sa fie cunoscuta (ramane in `held`, fiindca
        // fisierul este modificat local).
        let _ = self.refresh();
        let held = self.state().held.get(path).cloned();
        let Some(entry) = held else {
            (self.log)(&format!("EROARE    {path}: versiune schimbata pe server, dar nu o vad inca; reincerc"));
            return false;
        };
        let kept = self.conflict_name(path);
        let file = self.local(path);
        let (version, hash) = match self.api.upload(&kept, &file, local.size, local.mtime, 0) {
            Ok(result) => result,
            Err(e) => {
                (self.log)(&format!("EROARE    {kept}: {e}"));
                return false;
            }
        };
        (self.log)(&format!("CONFLICT  {path}: versiunea locala pastrata ca \"{kept}\""));
        self.state().files.insert(
            kept.clone(),
            Known { dir: false, size: local.size, hash, mtime: local.mtime, version, opened: 0 },
        );
        // Copia de conflict exista deja pe server; substituentul ei apare la urmatoarea trecere.
        match self.update(&entry, true) {
            Ok(()) => self.record(&entry),
            Err(e) => (self.log)(&format!("amanat    {path}: {e}")),
        }
        self.done(path);
        true
    }

    fn conflict_name(&self, path: &str) -> String {
        let (dir, base) = match path.rfind('/') {
            Some(i) => (&path[..=i], &path[i + 1..]),
            None => ("", path),
        };
        let (stem, ext) = match base.rfind('.') {
            Some(i) if i > 0 => (&base[..i], &base[i..]),
            _ => (base, ""),
        };
        let label = format!("conflict {} {}", date(now()), self.host);
        let mut candidate = format!("{dir}{stem} ({label}){ext}");
        let mut n = 2;
        while self.local(&candidate).exists() || self.state().files.contains_key(&candidate) {
            candidate = format!("{dir}{stem} ({label} {n}){ext}");
            n += 1;
        }
        candidate
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
            Ok(()) => {
                (self.log)(&format!("adus      {} (cerut de {})", request.path, request.who));
                self.touched(&request.path);
            }
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
            // Identitatea este calea de la creare; dupa o mutare, calea de acum este alta.
            let (path, known) = {
                let state = shared.state();
                let path = state.aliases.get(&request.path).cloned().unwrap_or_else(|| request.path.clone());
                let known = state.files.get(&path).cloned();
                (path, known)
            };
            let request = Fetch { path, ..request };
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

/// Un handle primit de la CfOpenFileWithOplock, inchis automat.
struct Opened(HANDLE);

impl Drop for Opened {
    fn drop(&mut self) {
        // SAFETY: handle-ul a fost primit de la CfOpenFileWithOplock si se inchide o singura data.
        unsafe { CfCloseHandle(self.0) };
    }
}

/// Ce ne cere sistemul cand un program deschide un substituent fara continut.
struct Fetch {
    path: String,
    connection: CF_CONNECTION_KEY,
    transfer: i64,
    request: i64,
    /// Programul care a cerut (daca sistemul ni l-a spus).
    who: String,
}

/// Programele carora nu le aducem continut: indexarea Windows ar descarca tot directorul
/// ca sa caute in el (numele fisierelor raman cautabile).
const NO_FETCH: &[&str] = &["searchprotocolhost.exe", "searchindexer.exe", "searchfilterhost.exe"];

/// Apelata de sistem (pe un fir al lui) cand trebuie adus continutul unui fisier.
unsafe extern "system" fn on_fetch_data(info: *const CF_CALLBACK_INFO, _params: *const CF_CALLBACK_PARAMETERS) {
    let Some(shared) = SHARED.get() else { return };
    // SAFETY: sistemul garanteaza ca `info` si identitatea fisierului sunt valide pe durata apelului.
    let (path, connection, transfer, request, who) = unsafe {
        let info = &*info;
        let identity = std::slice::from_raw_parts(info.FileIdentity.cast::<u8>(), info.FileIdentityLength as usize);
        (String::from_utf8_lossy(identity).into_owned(), info.ConnectionKey, info.TransferKey, info.RequestKey, caller(info))
    };
    let who = who.unwrap_or_default();
    let refused = NO_FETCH.contains(&who.as_str());
    let request = Fetch { path, connection, transfer, request, who };
    if refused {
        shared.transfer(&request, None);
        return;
    }
    shared.fetch(request);
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

/// Programele ale caror deschideri nu inseamna ca fisierul este folosit: Explorer (miniaturi,
/// previzualizari), gazda de miniaturi, indexarea Windows si clientul insusi.
const HOUSEKEEPING: &[&str] = &[
    "explorer.exe",
    "dllhost.exe",
    "searchprotocolhost.exe",
    "searchindexer.exe",
    "searchfilterhost.exe",
    "filesync-client.exe",
    "filesync-cloud.exe",
];

/// Numele programului care a facut cererea (din informatiile despre proces), cu litere mici.
unsafe fn caller(info: &CF_CALLBACK_INFO) -> Option<String> {
    if info.ProcessInfo.is_null() {
        return None;
    }
    // SAFETY: sistemul da o structura valida pe durata apelului, cu un sir terminat cu zero.
    unsafe {
        let process = &*info.ProcessInfo;
        if process.ImagePath.is_null() {
            return None;
        }
        let mut len = 0;
        while *process.ImagePath.add(len) != 0 {
            len += 1;
        }
        let path = String::from_utf16_lossy(std::slice::from_raw_parts(process.ImagePath, len));
        Some(path.rsplit(['\\', '/']).next().unwrap_or(&path).to_ascii_lowercase())
    }
}

/// Apelata de sistem dupa ce un program a deschis un fisier din director.
unsafe extern "system" fn on_open_completion(info: *const CF_CALLBACK_INFO, _params: *const CF_CALLBACK_PARAMETERS) {
    let Some(shared) = SHARED.get() else { return };
    // SAFETY: ca la on_fetch_data.
    let (identity, who) = unsafe {
        let info = &*info;
        let identity = std::slice::from_raw_parts(info.FileIdentity.cast::<u8>(), info.FileIdentityLength as usize);
        (String::from_utf8_lossy(identity).into_owned(), caller(info))
    };
    if who.as_deref().is_some_and(|w| HOUSEKEEPING.contains(&w)) {
        return;
    }
    shared.touched(&identity);
}

// --- inregistrarea pentru Explorer (WinRT) ---
// Da coloana "Status" cu iconite (nor, bifa), intrarea din bara laterala si numele furnizorului.
// Fara ea totul merge la fel; de aceea esecul ei este doar anuntat.

/// SID-ul utilizatorului curent, ca text ("S-1-5-21-...").
fn user_sid() -> Result<String, String> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TOKEN_USER, TokenUser};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: apeluri Win32 cu adrese valide; token-ul este inchis la sfarsit.
    unsafe {
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err("OpenProcessToken".into());
        }
        let mut needed = 0u32;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut needed);
        let mut buffer = vec![0u8; needed.max(64) as usize];
        let ok = GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), buffer.len() as u32, &mut needed);
        windows_sys::Win32::Foundation::CloseHandle(token);
        if ok == 0 {
            return Err("GetTokenInformation".into());
        }
        let user = &*(buffer.as_ptr() as *const TOKEN_USER);
        let mut text: *mut u16 = std::ptr::null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 || text.is_null() {
            return Err("ConvertSidToStringSid".into());
        }
        let mut len = 0;
        while *text.add(len) != 0 {
            len += 1;
        }
        let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
        LocalFree(text.cast());
        Ok(sid)
    }
}

/// Mesaj de eroare cu numele pasului care a esuat.
fn fail<E: std::fmt::Display>(what: &'static str) -> impl Fn(E) -> String {
    move |e| format!("{what}: {e}")
}

/// Identificatorul inregistrarii de shell: furnizor!SID!cont, forma ceruta de Windows.
fn shell_id(account: &str) -> Result<String, String> {
    Ok(format!("filesync!{}!{}", user_sid()?, account.replace('!', "_")))
}

fn shell_register(root: &Path, account: &str) -> Result<(), String> {
    use windows::Storage::Provider::{
        StorageProviderHardlinkPolicy, StorageProviderHydrationPolicy, StorageProviderHydrationPolicyModifier,
        StorageProviderInSyncPolicy, StorageProviderPopulationPolicy, StorageProviderProtectionMode,
        StorageProviderSyncRootInfo, StorageProviderSyncRootManager,
    };
    use windows::Storage::StorageFolder;
    use windows::core::{GUID, HSTRING};
    // SAFETY: initializarea WinRT pentru acest fir; a doua chemare este inofensiva.
    let _ = unsafe { windows::Win32::System::WinRT::RoInitialize(windows::Win32::System::WinRT::RO_INIT_MULTITHREADED) };
    let folder = StorageFolder::GetFolderFromPathAsync(&HSTRING::from(root.to_string_lossy().as_ref()))
        .map_err(fail("GetFolderFromPathAsync"))?
        .join()
        .map_err(fail("director"))?;
    let info = StorageProviderSyncRootInfo::new().map_err(fail("SyncRootInfo"))?;
    info.SetId(&HSTRING::from(shell_id(account)?)).map_err(fail("Id"))?;
    info.SetProviderId(GUID::from_values(
        PROVIDER_ID.data1,
        PROVIDER_ID.data2,
        PROVIDER_ID.data3,
        PROVIDER_ID.data4,
    ))
    .map_err(fail("ProviderId"))?;
    info.SetPath(&folder).map_err(fail("Path"))?;
    info.SetDisplayNameResource(&HSTRING::from(format!("filesync ({account})"))).map_err(fail("DisplayName"))?;
    info.SetIconResource(&HSTRING::from("%SystemRoot%\\system32\\imageres.dll,-1043")).map_err(fail("Icon"))?;
    info.SetVersion(&HSTRING::from(env!("CARGO_PKG_VERSION"))).map_err(fail("Version"))?;
    info.SetHydrationPolicy(StorageProviderHydrationPolicy::Full).map_err(fail("HydrationPolicy"))?;
    info.SetHydrationPolicyModifier(StorageProviderHydrationPolicyModifier::None).map_err(fail("HydrationPolicyModifier"))?;
    info.SetPopulationPolicy(StorageProviderPopulationPolicy::AlwaysFull).map_err(fail("PopulationPolicy"))?;
    let track_all = StorageProviderInSyncPolicy::FileCreationTime
        | StorageProviderInSyncPolicy::FileReadOnlyAttribute
        | StorageProviderInSyncPolicy::FileHiddenAttribute
        | StorageProviderInSyncPolicy::FileSystemAttribute
        | StorageProviderInSyncPolicy::FileLastWriteTime
        | StorageProviderInSyncPolicy::DirectoryCreationTime
        | StorageProviderInSyncPolicy::DirectoryReadOnlyAttribute
        | StorageProviderInSyncPolicy::DirectoryHiddenAttribute
        | StorageProviderInSyncPolicy::DirectorySystemAttribute
        | StorageProviderInSyncPolicy::DirectoryLastWriteTime;
    info.SetInSyncPolicy(track_all).map_err(fail("InSyncPolicy"))?;
    info.SetHardlinkPolicy(StorageProviderHardlinkPolicy::None).map_err(fail("HardlinkPolicy"))?;
    info.SetShowSiblingsAsGroup(false).map_err(fail("ShowSiblingsAsGroup"))?;
    info.SetProtectionMode(StorageProviderProtectionMode::Personal).map_err(fail("ProtectionMode"))?;
    StorageProviderSyncRootManager::Register(&info).map_err(fail("Register"))
}

fn shell_unregister(account: &str) -> Result<(), String> {
    use windows::Storage::Provider::StorageProviderSyncRootManager;
    use windows::core::HSTRING;
    // SAFETY: ca mai sus.
    let _ = unsafe { windows::Win32::System::WinRT::RoInitialize(windows::Win32::System::WinRT::RO_INIT_MULTITHREADED) };
    StorageProviderSyncRootManager::Unregister(&HSTRING::from(shell_id(account)?)).map_err(|e| e.to_string())
}
// --- sfarsitul inregistrarii pentru Explorer ---

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
pub fn unregister(target: &Path, account: &str) -> Result<(), String> {
    let root = target.canonicalize().map_err(|e| format!("{}: {e}", target.display()))?;
    if let Err(e) = shell_unregister(account) {
        println!("(inregistrarea de shell nu a putut fi scoasa: {e})");
    }
    let path = wide_path(&root);
    // SAFETY: `path` este un sir UTF-16 terminat cu zero.
    let hr = unsafe { CfUnregisterSyncRoot(path.as_ptr()) };
    check(hr, &format!("nu pot scoate inregistrarea pentru {}", root.display()))?;
    println!("Inregistrarea pentru {} a fost scoasa. Fisierele fara continut nu mai pot fi deschise;", root.display());
    println!("poti sterge directorul.");
    Ok(())
}

/// Porneste fisierele virtuale si ramane pornit pana la Ctrl+C.
pub fn run(
    api: Api,
    home: &Path,
    target: &Path,
    cache_limit: u64,
    host: String,
    account: &str,
    allow_mass_delete: bool,
    free_after: i64,
    log: fn(&str),
) -> Result<(), String> {
    // Pentru teste: pragul in secunde, si verificarea la fiecare trecere.
    let test_secs = std::env::var("FILESYNC_FREE_AFTER_SECS").ok().and_then(|v| v.parse::<i64>().ok());
    let free_after = test_secs.unwrap_or(free_after);
    let sweep_every = if test_secs.is_some() { Duration::from_secs(10) } else { Duration::from_secs(600) };
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
    let mut state = State::load(&state_path);
    // Starea de la o versiune mai veche nu stie cand au fost deschise fisierele: de acum.
    for k in state.files.values_mut().filter(|k| !k.dir && k.opened == 0) {
        k.opened = now();
    }

    // Inregistrarea pentru Explorer (iconite); daca nu merge, cea de baza ajunge.
    match shell_register(&root, account) {
        Ok(()) => {}
        Err(e) => {
            log(&format!("fara iconite in Explorer ({e}); functionarea nu este afectata"));
            register(&root)?;
        }
    }
    let shared = Arc::new(Shared {
        api,
        root: root.clone(),
        state: Mutex::new(state),
        state_path,
        cache,
        cache_limit,
        counter: AtomicU64::new(0),
        host,
        allow_mass_delete,
        free_after,
        quiet: Mutex::new(HashSet::new()),
        log,
    });
    SHARED.set(shared.clone()).map_err(|_| "pornit de doua ori".to_string())?;

    let callbacks = [
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_FETCH_DATA, Callback: Some(on_fetch_data) },
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, Callback: Some(on_cancel_fetch_data) },
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_NOTIFY_FILE_OPEN_COMPLETION, Callback: Some(on_open_completion) },
        CF_CALLBACK_REGISTRATION { Type: CF_CALLBACK_TYPE_NONE, Callback: None },
    ];
    let path = wide_path(&root);
    let mut connection: CF_CONNECTION_KEY = 0;
    // SAFETY: tabelul se incheie cu CF_CALLBACK_TYPE_NONE; `connection` primeste cheia.
    let hr = unsafe {
        CfConnectSyncRoot(path.as_ptr(), callbacks.as_ptr(), std::ptr::null(), CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO, &mut connection)
    };
    check(hr, &format!("nu ma pot lega de {}", root.display()))?;

    shared.fix_dir_dates();
    match shared.refresh() {
        Ok(n) => {
            log(&format!("Fisiere virtuale in {} ({n} schimbari la pornire). Opreste cu Ctrl+C sau `filesync-client stop`.", root.display()));
            shared.push();
        }
        Err(e) => log(&format!("Fisiere virtuale in {}; serverul nu raspunde acum ({e}). Opreste cu Ctrl+C sau `filesync-client stop`.", root.display())),
    }

    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    ctrlc::set_handler(move || flag.store(true, Ordering::SeqCst)).map_err(|e| e.to_string())?;
    let stop_file = home.join("stop");
    let _ = std::fs::remove_file(&stop_file);
    // Notificarile de la sistem spun cand merita o scanare; fara ele, scanam la fiecare
    // trecere; cu ele, o scanare completa ramane doar la 5 minute, ca plasa de siguranta.
    let watcher = match crate::watch::Watch::new(&root) {
        Ok(w) => Some(w),
        Err(e) => {
            log(&format!("fara notificari de la sistem ({e}); scanez la fiecare 10 secunde"));
            None
        }
    };
    let stop_asked = || stop.load(Ordering::SeqCst) || stop_file.exists();
    let mut last = Instant::now();
    let mut last_push = Instant::now();
    let mut last_sweep = Instant::now();
    let mut down = false;
    loop {
        let remaining = Duration::from_secs(10).saturating_sub(last.elapsed()).max(Duration::from_millis(200));
        let wake = match &watcher {
            Some(w) => w.wait(remaining, &stop_asked),
            None => crate::watch::sleep(remaining, &stop_asked),
        };
        match wake {
            crate::watch::Wake::Stop => break,
            crate::watch::Wake::Changed => {
                shared.push();
                last_push = Instant::now();
            }
            crate::watch::Wake::Timeout => {}
        }
        if last_sweep.elapsed() >= sweep_every {
            shared.free_space();
            last_sweep = Instant::now();
        }
        if last.elapsed() >= Duration::from_secs(10) {
            match shared.refresh() {
                Ok(_) => {
                    if down {
                        log("serverul raspunde din nou");
                        down = false;
                    }
                    if watcher.is_none() || last_push.elapsed() >= Duration::from_secs(300) {
                        shared.push();
                        last_push = Instant::now();
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
    let _ = std::fs::remove_file(&stop_file);
    check(hr, "dezlegare")?;
    log("Oprit. Fisierele raman in director; cele neaduse se aduc la urmatoarea pornire.");
    Ok(())
}
