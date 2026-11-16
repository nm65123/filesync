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
