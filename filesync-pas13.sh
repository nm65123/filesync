#!/bin/bash
# filesync, pasul 13: pe macOS discul virtual se monteaza direct prin unealta macFUSE (fara libfuse).
# Ruleaza pe serverul filesync:  bash filesync-pas13.sh
cd ~/filesync || exit 1
source ~/.cargo/env 2>/dev/null
cat > client/src/mount.rs <<'FILESYNC_EOF'
//! Disc virtual (FUSE, Linux si macOS): fisierele de pe server apar intr-un director
//! montat, fara sa ocupe spatiu. Continutul este adus la prima deschidere si tinut
//! intr-un cache local cu marime limitata. Ce se scrie este urcat la inchiderea fisierului.

use crate::api::{Api, Entry, Fail};
use crate::scan::ignored;
use crate::sync::{date, now};
use fuser::{
    Errno, FileAttr, FileHandle, FileType, Filesystem, FopenFlags, Generation, INodeNo, LockOwner,
    MountOption, OpenFlags, RenameFlags, ReplyAttr, ReplyCreate, ReplyData, ReplyDirectory,
    ReplyEmpty, ReplyEntry, ReplyOpen, ReplyStatfs, ReplyWrite, Request, TimeOrNow, WriteFlags,
};
use std::collections::{BTreeMap, HashMap};
use std::ffi::OsStr;
use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const TTL: Duration = Duration::from_secs(1);
const ROOT: u64 = 1;

#[derive(Clone)]
struct Node {
    /// Calea relativa, cu "/"; goala pentru radacina.
    path: String,
    dir: bool,
    size: u64,
    mtime: i64,
    hash: String,
    /// Versiunea de pe server; 0 = inca nu exista pe server.
    version: i64,
    /// Fisierul local cu continutul scris aici (cat timp difera de server sau este deschis).
    local: Option<PathBuf>,
    /// Are modificari care trebuie urcate.
    dirty: bool,
    /// Fisier temporar (~$..., *.tmp): traieste doar local, nu se urca.
    local_only: bool,
}

struct Tree {
    nodes: HashMap<u64, Node>,
    by_path: HashMap<String, u64>,
    children: HashMap<u64, BTreeMap<String, u64>>,
    next_ino: u64,
    cursor: i64,
    refreshed: Option<Instant>,
    /// Dupa o incercare esuata (server inaccesibil), urmatoarea se face abia dupa acest moment.
    retry_after: Option<Instant>,
    /// Modificari venite de pe server pentru fisiere care au schimbari locale neurcate.
    held: HashMap<String, Entry>,
}

fn parent_of(path: &str) -> &str {
    path.rfind('/').map(|i| &path[..i]).unwrap_or("")
}

fn name_of(path: &str) -> &str {
    path.rfind('/').map(|i| &path[i + 1..]).unwrap_or(path)
}

fn join(parent: &str, name: &str) -> String {
    if parent.is_empty() { name.to_string() } else { format!("{parent}/{name}") }
}

fn dir_node(path: &str) -> Node {
    Node {
        path: path.to_string(),
        dir: true,
        size: 0,
        mtime: now(),
        hash: String::new(),
        version: 0,
        local: None,
        dirty: false,
        local_only: false,
    }
}

impl Tree {
    fn new() -> Tree {
        let mut tree = Tree {
            nodes: HashMap::new(),
            by_path: HashMap::new(),
            children: HashMap::new(),
            next_ino: ROOT + 1,
            cursor: 0,
            refreshed: None,
            retry_after: None,
            held: HashMap::new(),
        };
        tree.nodes.insert(ROOT, dir_node(""));
        tree.by_path.insert(String::new(), ROOT);
        tree.children.insert(ROOT, BTreeMap::new());
        tree
    }

    fn ino(&self, path: &str) -> Option<u64> {
        self.by_path.get(path).copied()
    }

    fn child(&self, parent: u64, name: &str) -> Option<u64> {
        self.children.get(&parent)?.get(name).copied()
    }

    /// Directorul cu aceasta cale, creat impreuna cu parintii lui daca lipseste.
    fn ensure_dir(&mut self, path: &str) -> u64 {
        if let Some(ino) = self.ino(path) {
            return ino;
        }
        self.put(dir_node(path))
    }

    /// Adauga sau inlocuieste un nod; numarul de inod se pastreaza daca exista deja.
    fn put(&mut self, node: Node) -> u64 {
        if let Some(ino) = self.ino(&node.path) {
            let was_dir = self.nodes.get(&ino).is_some_and(|n| n.dir);
            if was_dir == node.dir {
                self.nodes.insert(ino, node);
                return ino;
            }
            self.remove(&node.path.clone());
        }
        let parent = self.ensure_dir(parent_of(&node.path));
        let ino = self.next_ino;
        self.next_ino += 1;
        self.children
            .entry(parent)
            .or_default()
            .insert(name_of(&node.path).to_string(), ino);
        if node.dir {
            self.children.insert(ino, BTreeMap::new());
        }
        self.by_path.insert(node.path.clone(), ino);
        self.nodes.insert(ino, node);
        ino
    }

    /// Nodul si tot ce este sub el.
    fn subtree(&self, ino: u64) -> Vec<u64> {
        let mut all = vec![ino];
        let mut i = 0;
        while i < all.len() {
            if let Some(children) = self.children.get(&all[i]) {
                all.extend(children.values());
            }
            i += 1;
        }
        all
    }

    /// Scoate un nod cu tot ce este sub el. Intoarce fisierele locale ramase fara stapan.
    fn remove(&mut self, path: &str) -> Vec<PathBuf> {
        let Some(ino) = self.ino(path) else { return Vec::new() };
        if ino == ROOT {
            return Vec::new();
        }
        let mut orphans = Vec::new();
        for id in self.subtree(ino) {
            if let Some(node) = self.nodes.remove(&id) {
                self.by_path.remove(&node.path);
                self.held.remove(&node.path);
                orphans.extend(node.local);
            }
            self.children.remove(&id);
        }
        if let Some(parent) = self.ino(parent_of(path)) {
            if let Some(children) = self.children.get_mut(&parent) {
                children.remove(name_of(path));
            }
        }
        orphans
    }

    /// Muta un nod (cu tot ce este sub el) la alta cale; ce era la destinatie dispare.
    fn rename(&mut self, from: &str, to: &str) -> Vec<PathBuf> {
        let Some(ino) = self.ino(from) else { return Vec::new() };
        let orphans = self.remove(to);
        if let Some(parent) = self.ino(parent_of(from)) {
            if let Some(children) = self.children.get_mut(&parent) {
                children.remove(name_of(from));
            }
        }
        for id in self.subtree(ino) {
            if let Some(node) = self.nodes.get_mut(&id) {
                self.by_path.remove(&node.path);
                node.path = format!("{to}{}", &node.path[from.len()..]);
                self.by_path.insert(node.path.clone(), id);
            }
        }
        let parent = self.ensure_dir(parent_of(to));
        self.children.entry(parent).or_default().insert(name_of(to).to_string(), ino);
        orphans
    }
}

struct Handle {
    ino: u64,
    writable: bool,
    /// Deschis abia la prima citire sau scriere.
    file: Option<File>,
    /// `file` este fisierul local de lucru (nu copia din cache).
    staged: bool,
}

struct Shared {
    api: Api,
    tree: Mutex<Tree>,
    handles: Mutex<HashMap<u64, Handle>>,
    next_fh: AtomicU64,
    counter: AtomicU64,
    cache: PathBuf,
    staging: PathBuf,
    cache_limit: u64,
    uid: u32,
    gid: u32,
    host: String,
    log: fn(&str),
}

fn io_error(e: std::io::Error) -> Errno {
    e.raw_os_error().map(Errno::from_i32).unwrap_or(Errno::EIO)
}

impl Shared {
    fn tree(&self) -> MutexGuard<'_, Tree> {
        self.tree.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn handles(&self) -> MutexGuard<'_, HashMap<u64, Handle>> {
        self.handles.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn attr(&self, ino: u64, node: &Node) -> FileAttr {
        let time = UNIX_EPOCH + Duration::from_secs(node.mtime.max(0) as u64);
        FileAttr {
            ino: INodeNo(ino),
            size: node.size,
            blocks: node.size.div_ceil(512),
            atime: time,
            mtime: time,
            ctime: time,
            crtime: time,
            kind: if node.dir { FileType::Directory } else { FileType::RegularFile },
            perm: if node.dir { 0o755 } else { 0o644 },
            nlink: if node.dir { 2 } else { 1 },
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            flags: 0,
            blksize: 4096,
        }
    }

    fn open_count(&self, ino: u64) -> usize {
        self.handles().values().filter(|h| h.ino == ino).count()
    }

    /// Aduce in arbore ce s-a schimbat pe server. Fara `force`, cel mult o data la 2 secunde.
    fn refresh(&self, force: bool) -> Result<(), Fail> {
        let cursor = {
            let tree = self.tree();
            if !force && tree.refreshed.is_some_and(|t| t.elapsed() < Duration::from_secs(2)) {
                return Ok(());
            }
            // Cu serverul inaccesibil nu blocam fiecare operatie asteptand reteaua.
            if !force && tree.retry_after.is_some_and(|t| Instant::now() < t) {
                return Ok(());
            }
            tree.cursor
        };
        let (entries, new_cursor) = match self.api.changes(cursor) {
            Ok(result) => result,
            Err(e) => {
                let mut tree = self.tree();
                if tree.retry_after.is_none() {
                    (self.log)(&format!("serverul nu raspunde ({e}); arat ce stiam si reincerc periodic"));
                }
                tree.retry_after = Some(Instant::now() + Duration::from_secs(30));
                return Err(e);
            }
        };
        let mut orphans = Vec::new();
        {
            let mut tree = self.tree();
            if tree.cursor == cursor {
                for entry in entries {
                    orphans.extend(Self::apply(&mut tree, entry));
                }
                tree.cursor = new_cursor;
            }
            if tree.retry_after.take().is_some() {
                (self.log)("serverul raspunde din nou");
            }
            tree.refreshed = Some(Instant::now());
        }
        for path in orphans {
            let _ = std::fs::remove_file(path);
        }
        Ok(())
    }

    /// Aplica o modificare venita de pe server.
    fn apply(tree: &mut Tree, entry: Entry) -> Vec<PathBuf> {
        let existing = tree.ino(&entry.path).and_then(|ino| tree.nodes.get(&ino).cloned());
        if let Some(node) = &existing {
            // Schimbarile locale neurcate au prioritate; ce a venit se tine minte pentru conflict.
            if node.local_only {
                return Vec::new();
            }
            if node.dirty || (node.version == 0 && !node.dir) {
                tree.held.insert(entry.path.clone(), entry);
                return Vec::new();
            }
        }
        if entry.deleted {
            return if existing.is_some() { tree.remove(&entry.path) } else { Vec::new() };
        }
        match existing {
            Some(node) if node.dir && entry.dir => Vec::new(),
            Some(node) if !node.dir && !entry.dir && node.version == entry.version => Vec::new(),
            existing => {
                // Continutul de pe server este altul: copia locala de lucru nu mai este buna.
                let orphans = existing.and_then(|n| n.local).into_iter().collect();
                tree.put(Node {
                    path: entry.path,
                    dir: entry.dir,
                    size: entry.size,
                    // Serverul nu tine data directoarelor; aratam momentul in care le-am aflat.
                    mtime: if entry.dir && entry.mtime == 0 { now() } else { entry.mtime },
                    hash: entry.hash,
                    version: entry.version,
                    local: None,
                    dirty: false,
                    local_only: false,
                });
                orphans
            }
        }
    }

    fn temp(&self, dir: &Path, prefix: &str) -> PathBuf {
        let n = self.counter.fetch_add(1, Ordering::Relaxed);
        dir.join(format!("{prefix}{}-{n}", std::process::id()))
    }

    /// Calea din cache a continutului unui fisier; il descarca daca lipseste.
    fn cached(&self, node: &Node) -> Result<PathBuf, Errno> {
        let path = self.cache.join(&node.hash);
        if path.exists() {
            // Data fisierului din cache tine minte ultima folosire.
            if let Ok(file) = File::options().write(true).open(&path) {
                let _ = file.set_modified(SystemTime::now());
            }
            return Ok(path);
        }
        let tmp = self.temp(&self.cache, ".part-");
        match self.api.download(&node.path, &tmp) {
            Ok(hash) if hash == node.hash => {}
            Ok(_) => {
                // S-a schimbat pe server intre timp; la urmatoarea incercare se vede versiunea noua.
                let _ = std::fs::remove_file(&tmp);
                let _ = self.refresh(true);
                return Err(Errno::EAGAIN);
            }
            Err(e) => {
                let _ = std::fs::remove_file(&tmp);
                (self.log)(&format!("EROARE    {}: {e}", node.path));
                return Err(Errno::EIO);
            }
        }
        std::fs::rename(&tmp, &path).map_err(io_error)?;
        (self.log)(&format!("adus      {}", node.path));
        self.evict(&path);
        Ok(path)
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

    /// Fisierul local de lucru al unui nod; il creeaza (copiind continutul curent) daca lipseste.
    fn stage(&self, ino: u64, empty: bool) -> Result<PathBuf, Errno> {
        let node = self.tree().nodes.get(&ino).cloned().ok_or(Errno::ENOENT)?;
        if let Some(path) = node.local {
            return Ok(path);
        }
        let path = self.temp(&self.staging, "");
        if empty || node.version == 0 {
            File::create(&path).map_err(io_error)?;
        } else {
            let source = self.cached(&node)?;
            std::fs::copy(&source, &path).map_err(io_error)?;
        }
        let mut tree = self.tree();
        match tree.nodes.get_mut(&ino) {
            // Altcineva a apucat sa il creeze intre timp.
            Some(current) if current.local.is_some() => {
                let _ = std::fs::remove_file(&path);
                Ok(current.local.clone().unwrap_or(path))
            }
            Some(current) => {
                current.local = Some(path.clone());
                Ok(path)
            }
            None => {
                let _ = std::fs::remove_file(&path);
                Err(Errno::ENOENT)
            }
        }
    }

    fn conflict_path(&self, tree: &Tree, path: &str) -> String {
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
        while tree.by_path.contains_key(&candidate) {
            candidate = format!("{dir}{stem} ({label} {n}){ext}");
            n += 1;
        }
        candidate
    }

    /// Urca pe server modificarile locale ale unui fisier.
    fn upload(&self, ino: u64) -> Result<(), Errno> {
        let Some(node) = self.tree().nodes.get(&ino).cloned() else { return Ok(()) };
        if !node.dirty || node.local_only || node.dir {
            return Ok(());
        }
        let Some(staging) = node.local.clone() else { return Ok(()) };
        let size = std::fs::metadata(&staging).map_err(io_error)?.len();
        match self.api.upload(&node.path, &staging, size, node.mtime, node.version) {
            Ok((version, hash)) => {
                let mut tree = self.tree();
                tree.held.remove(&node.path);
                if let Some(current) = tree.nodes.get_mut(&ino) {
                    // Daca s-a mai scris in timpul urcarii, ramane de urcat din nou.
                    let unchanged = current.size == size && current.mtime == node.mtime;
                    current.version = version;
                    current.hash = hash;
                    current.dirty = !unchanged;
                }
                (self.log)(&format!("urcat     {}", node.path));
                Ok(())
            }
            Err(Fail::Conflict) => self.keep_as_conflict(ino, &node, &staging, size),
            Err(e) => {
                (self.log)(&format!("EROARE    {}: {e}", node.path));
                Err(Errno::EIO)
            }
        }
    }

    /// Fisierul s-a schimbat si pe server: versiunea locala este urcata sub alt nume,
    /// iar sub numele original ramane versiunea de pe server.
    fn keep_as_conflict(&self, ino: u64, node: &Node, staging: &Path, size: u64) -> Result<(), Errno> {
        let kept = {
            let tree = self.tree();
            self.conflict_path(&tree, &node.path)
        };
        let (version, hash) = self.api.upload(&kept, staging, size, node.mtime, 0).map_err(|e| {
            (self.log)(&format!("EROARE    {kept}: {e}"));
            Errno::EIO
        })?;
        (self.log)(&format!("CONFLICT  {}: versiunea locala pastrata ca \"{kept}\"", node.path));
        let mut orphans = Vec::new();
        {
            let mut tree = self.tree();
            tree.put(Node {
                path: kept,
                dir: false,
                size,
                mtime: node.mtime,
                hash,
                version,
                local: None,
                dirty: false,
                local_only: false,
            });
            let held = tree.held.remove(&node.path);
            if let Some(current) = tree.nodes.get_mut(&ino) {
                current.dirty = false;
                current.version = -1; // necunoscuta: orice vine de pe server o inlocuieste
                orphans.extend(current.local.take());
            }
            if let Some(entry) = held {
                orphans.extend(Self::apply(&mut tree, entry));
            }
        }
        for path in orphans {
            let _ = std::fs::remove_file(path);
        }
        let _ = self.refresh(true);
        Ok(())
    }

    /// Dupa inchiderea ultimului descriptor: continutul urcat trece in cache.
    fn settle(&self, ino: u64) {
        if self.open_count(ino) > 0 {
            return;
        }
        let mut tree = self.tree();
        let Some(node) = tree.nodes.get_mut(&ino) else { return };
        if node.dirty || node.local_only || node.version <= 0 || node.hash.is_empty() {
            return;
        }
        if let Some(staging) = node.local.take() {
            let target = self.cache.join(&node.hash);
            if target.exists() || std::fs::rename(&staging, &target).is_err() {
                let _ = std::fs::remove_file(&staging);
            }
        }
    }

    /// Mai incearca sa urce ce a ramas neurcat (de exemplu dupa o pana de retea).
    fn retry_pending(&self) {
        let pending: Vec<u64> = self
            .tree()
            .nodes
            .iter()
            .filter(|(_, n)| n.dirty && !n.local_only && !n.dir)
            .map(|(ino, _)| *ino)
            .collect();
        for ino in pending {
            if self.open_count(ino) == 0 && self.upload(ino).is_ok() {
                self.settle(ino);
            }
        }
    }

    /// Descriptorul fisierului din spatele unui handle, deschis la nevoie.
    fn backing(&self, fh: u64, for_write: bool, empty: bool) -> Result<File, Errno> {
        let (ino, staged, existing) = {
            let handles = self.handles();
            let handle = handles.get(&fh).ok_or(Errno::EBADF)?;
            if for_write && !handle.writable {
                return Err(Errno::EBADF);
            }
            (handle.ino, handle.staged, handle.file.as_ref().map(File::try_clone))
        };
        if let Some(file) = existing {
            if staged || !for_write {
                return file.map_err(io_error);
            }
        }
        let node = self.tree().nodes.get(&ino).cloned().ok_or(Errno::ENOENT)?;
        let (file, staged) = if for_write || node.local.is_some() {
            let path = self.stage(ino, empty)?;
            (File::options().read(true).write(true).open(path).map_err(io_error)?, true)
        } else {
            (File::open(self.cached(&node)?).map_err(io_error)?, false)
        };
        let copy = file.try_clone().map_err(io_error)?;
        if let Some(handle) = self.handles().get_mut(&fh) {
            handle.file = Some(file);
            handle.staged = staged;
        }
        Ok(copy)
    }

    fn new_handle(&self, ino: u64, writable: bool, file: Option<File>, staged: bool) -> u64 {
        let fh = self.next_fh.fetch_add(1, Ordering::Relaxed);
        self.handles().insert(fh, Handle { ino, writable, file, staged });
        fh
    }

    fn reply_entry(&self, ino: u64, reply: ReplyEntry) {
        match self.tree().nodes.get(&ino) {
            Some(node) => reply.entry(&TTL, &self.attr(ino, node), Generation(0)),
            None => reply.error(Errno::ENOENT),
        }
    }
}

pub struct Drive(Arc<Shared>);

impl Filesystem for Drive {
    fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
        let _ = self.0.refresh(false);
        let found = name.to_str().and_then(|name| self.0.tree().child(parent.0, name));
        match found {
            Some(ino) => self.0.reply_entry(ino, reply),
            None => reply.error(Errno::ENOENT),
        }
    }

    fn getattr(&self, _req: &Request, ino: INodeNo, _fh: Option<FileHandle>, reply: ReplyAttr) {
        match self.0.tree().nodes.get(&ino.0) {
            Some(node) => reply.attr(&TTL, &self.0.attr(ino.0, node)),
            None => reply.error(Errno::ENOENT),
        }
    }

    fn readdir(&self, _req: &Request, ino: INodeNo, _fh: FileHandle, offset: u64, mut reply: ReplyDirectory) {
        let _ = self.0.refresh(false);
        let tree = self.0.tree();
        let Some(node) = tree.nodes.get(&ino.0).filter(|n| n.dir) else {
            return reply.error(Errno::ENOTDIR);
        };
        let parent = tree.ino(parent_of(&node.path)).unwrap_or(ROOT);
        let mut entries = vec![(ino.0, FileType::Directory, ".".to_string()), (parent, FileType::Directory, "..".to_string())];
        if let Some(children) = tree.children.get(&ino.0) {
            for (name, child) in children {
                let kind = match tree.nodes.get(child) {
                    Some(n) if n.dir => FileType::Directory,
                    _ => FileType::RegularFile,
                };
                entries.push((*child, kind, name.clone()));
            }
        }
        for (i, (child, kind, name)) in entries.into_iter().enumerate().skip(offset as usize) {
            if reply.add(INodeNo(child), (i + 1) as u64, kind, name) {
                break;
            }
        }
        reply.ok();
    }

    fn open(&self, _req: &Request, ino: INodeNo, flags: OpenFlags, reply: ReplyOpen) {
        match self.0.tree().nodes.get(&ino.0) {
            Some(node) if node.dir => return reply.error(Errno::EISDIR),
            Some(_) => {}
            None => return reply.error(Errno::ENOENT),
        }
        let writable = flags.0 & libc::O_ACCMODE != libc::O_RDONLY;
        let fh = self.0.new_handle(ino.0, writable, None, false);
        if writable && flags.0 & libc::O_TRUNC != 0 {
            if let Err(e) = self.truncate(ino.0, Some(fh), 0) {
                self.0.handles().remove(&fh);
                return reply.error(e);
            }
        }
        reply.opened(FileHandle(fh), FopenFlags::empty());
    }

    fn create(&self, _req: &Request, parent: INodeNo, name: &OsStr, _mode: u32, _umask: u32, _flags: i32, reply: ReplyCreate) {
        let Some(name) = name.to_str() else { return reply.error(Errno::EINVAL) };
        let staging = self.0.temp(&self.0.staging, "");
        let file = match File::options().read(true).write(true).create_new(true).open(&staging) {
            Ok(file) => file,
            Err(e) => return reply.error(io_error(e)),
        };
        let (ino, attr) = {
            let mut tree = self.0.tree();
            let Some(parent_path) = tree.nodes.get(&parent.0).filter(|n| n.dir).map(|n| n.path.clone()) else {
                let _ = std::fs::remove_file(&staging);
                return reply.error(Errno::ENOENT);
            };
            let path = join(&parent_path, name);
            // Daca exista deja pe server, urcarea il inlocuieste (versiunea lui se pastreaza).
            let version = tree.ino(&path).and_then(|i| tree.nodes.get(&i)).map(|n| n.version).unwrap_or(0);
            let ino = tree.put(Node {
                path,
                dir: false,
                size: 0,
                mtime: now(),
                hash: String::new(),
                version,
                local: Some(staging),
                dirty: true,
                local_only: ignored(name),
            });
            (ino, self.0.attr(ino, &tree.nodes[&ino]))
        };
        let fh = self.0.new_handle(ino, true, Some(file), true);
        reply.created(&TTL, &attr, Generation(0), FileHandle(fh), FopenFlags::empty());
    }

    fn read(&self, _req: &Request, _ino: INodeNo, fh: FileHandle, offset: u64, size: u32, _flags: OpenFlags, _lock: Option<LockOwner>, reply: ReplyData) {
        let file = match self.0.backing(fh.0, false, false) {
            Ok(file) => file,
            Err(e) => return reply.error(e),
        };
        let mut buffer = vec![0u8; size as usize];
        let mut filled = 0;
        while filled < buffer.len() {
            match file.read_at(&mut buffer[filled..], offset + filled as u64) {
                Ok(0) => break,
                Ok(n) => filled += n,
                Err(e) => return reply.error(io_error(e)),
            }
        }
        reply.data(&buffer[..filled]);
    }

    fn write(&self, _req: &Request, ino: INodeNo, fh: FileHandle, offset: u64, data: &[u8], _write_flags: WriteFlags, _flags: OpenFlags, _lock: Option<LockOwner>, reply: ReplyWrite) {
        let file = match self.0.backing(fh.0, true, false) {
            Ok(file) => file,
            Err(e) => return reply.error(e),
        };
        if let Err(e) = file.write_all_at(data, offset) {
            return reply.error(io_error(e));
        }
        if let Some(node) = self.0.tree().nodes.get_mut(&ino.0) {
            node.size = node.size.max(offset + data.len() as u64);
            node.mtime = now();
            node.dirty = true;
        }
        reply.written(data.len() as u32);
    }

    fn flush(&self, _req: &Request, ino: INodeNo, fh: FileHandle, _lock: LockOwner, reply: ReplyEmpty) {
        // La inchidere, ce s-a scris pleaca pe server; programul afla daca nu a reusit.
        let writable = self.0.handles().get(&fh.0).is_some_and(|h| h.writable);
        // Un fisier nou, inca gol, asteapta: multe programe inchid o copie a descriptorului
        // inainte sa scrie. Daca ramane gol, este urcat la inchiderea finala.
        let still_empty = self.0.tree().nodes.get(&ino.0).is_some_and(|n| n.version == 0 && n.size == 0);
        if writable && !still_empty {
            if let Err(e) = self.0.upload(ino.0) {
                return reply.error(e);
            }
        }
        reply.ok();
    }

    fn release(&self, _req: &Request, ino: INodeNo, fh: FileHandle, _flags: OpenFlags, _lock: Option<LockOwner>, _flush: bool, reply: ReplyEmpty) {
        let handle = self.0.handles().remove(&fh.0);
        if handle.is_some_and(|h| h.writable) {
            let _ = self.0.upload(ino.0); // daca nu reuseste, se reincearca in fundal
        }
        self.0.settle(ino.0);
        reply.ok();
    }

    fn fsync(&self, _req: &Request, _ino: INodeNo, _fh: FileHandle, _datasync: bool, reply: ReplyEmpty) {
        reply.ok();
    }

    fn setattr(
        &self,
        _req: &Request,
        ino: INodeNo,
        _mode: Option<u32>,
        _uid: Option<u32>,
        _gid: Option<u32>,
        size: Option<u64>,
        _atime: Option<TimeOrNow>,
        mtime: Option<TimeOrNow>,
        _ctime: Option<SystemTime>,
        fh: Option<FileHandle>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<fuser::BsdFileFlags>,
        reply: ReplyAttr,
    ) {
        if let Some(size) = size {
            if let Err(e) = self.truncate(ino.0, fh.map(|f| f.0), size) {
                return reply.error(e);
            }
        }
        if let Some(time) = mtime {
            let secs = match time {
                TimeOrNow::SpecificTime(t) => t.duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0),
                TimeOrNow::Now => now(),
            };
            // Data conteaza doar pentru fisierele care urmeaza sa fie urcate (cp -p, rsync -t).
            if let Some(node) = self.0.tree().nodes.get_mut(&ino.0) {
                if node.dirty || node.local.is_some() {
                    node.mtime = secs;
                    node.dirty = node.dirty || !node.local_only;
                }
            }
        }
        if size.is_some() && fh.is_none() && self.0.open_count(ino.0) == 0 {
            if let Err(e) = self.0.upload(ino.0) {
                return reply.error(e);
            }
            self.0.settle(ino.0);
        }
        match self.0.tree().nodes.get(&ino.0) {
            Some(node) => reply.attr(&TTL, &self.0.attr(ino.0, node)),
            None => reply.error(Errno::ENOENT),
        }
    }

    fn mkdir(&self, _req: &Request, parent: INodeNo, name: &OsStr, _mode: u32, _umask: u32, reply: ReplyEntry) {
        let Some(name) = name.to_str() else { return reply.error(Errno::EINVAL) };
        let Some(parent_path) = self.0.tree().nodes.get(&parent.0).filter(|n| n.dir).map(|n| n.path.clone()) else {
            return reply.error(Errno::ENOENT);
        };
        let path = join(&parent_path, name);
        if self.0.tree().ino(&path).is_some() {
            return reply.error(Errno::EEXIST);
        }
        if let Err(e) = self.0.api.mkdir(&path) {
            (self.0.log)(&format!("EROARE    {path}: {e}"));
            return reply.error(Errno::EIO);
        }
        let ino = self.0.tree().put(dir_node(&path));
        self.0.reply_entry(ino, reply);
    }

    fn unlink(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        let found = {
            let tree = self.0.tree();
            name.to_str()
                .and_then(|name| tree.child(parent.0, name))
                .and_then(|ino| tree.nodes.get(&ino).cloned())
        };
        let Some(node) = found else { return reply.error(Errno::ENOENT) };
        if node.dir {
            return reply.error(Errno::EISDIR);
        }
        if node.version != 0 && !node.local_only {
            // Stergem ce vedem aici, chiar daca pe server a aparut intre timp alta versiune.
            if let Err(e) = self.0.api.delete(&node.path, None) {
                (self.0.log)(&format!("EROARE    {}: {e}", node.path));
                return reply.error(Errno::EIO);
            }
            (self.0.log)(&format!("sters     {}", node.path));
        }
        for path in self.0.tree().remove(&node.path) {
            let _ = std::fs::remove_file(path);
        }
        reply.ok();
    }

    fn rmdir(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        let found = {
            let tree = self.0.tree();
            name.to_str().and_then(|name| tree.child(parent.0, name)).map(|ino| {
                let empty = tree.children.get(&ino).is_none_or(|c| c.is_empty());
                (tree.nodes.get(&ino).cloned(), empty)
            })
        };
        let Some((Some(node), empty)) = found else { return reply.error(Errno::ENOENT) };
        if !node.dir {
            return reply.error(Errno::ENOTDIR);
        }
        if !empty {
            return reply.error(Errno::ENOTEMPTY);
        }
        match self.0.api.delete(&node.path, None) {
            Ok(()) => {}
            Err(Fail::Refused(m)) if m.starts_with("409") => return reply.error(Errno::ENOTEMPTY),
            Err(e) => {
                (self.0.log)(&format!("EROARE    {}: {e}", node.path));
                return reply.error(Errno::EIO);
            }
        }
        self.0.tree().remove(&node.path);
        reply.ok();
    }

    fn rename(&self, _req: &Request, parent: INodeNo, name: &OsStr, newparent: INodeNo, newname: &OsStr, _flags: RenameFlags, reply: ReplyEmpty) {
        let (Some(name), Some(newname)) = (name.to_str(), newname.to_str()) else {
            return reply.error(Errno::EINVAL);
        };
        let (ino, node, to, target_version) = {
            let tree = self.0.tree();
            let Some(ino) = tree.child(parent.0, name) else { return reply.error(Errno::ENOENT) };
            let Some(node) = tree.nodes.get(&ino).cloned() else { return reply.error(Errno::ENOENT) };
            let Some(new_parent) = tree.nodes.get(&newparent.0).filter(|n| n.dir) else {
                return reply.error(Errno::ENOENT);
            };
            let to = join(&new_parent.path, newname);
            let target = tree.ino(&to).and_then(|i| tree.nodes.get(&i));
            if target.is_some_and(|t| t.dir != node.dir) {
                return reply.error(if node.dir { Errno::ENOTDIR } else { Errno::EISDIR });
            }
            (ino, node, to.clone(), target.map(|t| t.version).unwrap_or(0))
        };
        if to == node.path {
            return reply.ok();
        }

        let on_server = node.dir || (node.version != 0 && !node.local_only);
        if on_server {
            // Intai urcam ce este scris si neurcat, apoi mutam pe server.
            if node.dirty && self.0.upload(ino).is_err() {
                return reply.error(Errno::EIO);
            }
            if let Err(e) = self.0.api.rename(&node.path, &to) {
                (self.0.log)(&format!("EROARE    {} -> {to}: {e}", node.path));
                return reply.error(Errno::EIO);
            }
            (self.0.log)(&format!("mutat     {} -> {to}", node.path));
            let orphans = {
                let mut tree = self.0.tree();
                let orphans = tree.rename(&node.path, &to);
                // Versiunile de la noua cale se afla de pe server.
                for id in tree.subtree(ino) {
                    if let Some(n) = tree.nodes.get_mut(&id) {
                        if !n.dir && !n.dirty {
                            n.version = -1;
                        }
                    }
                }
                orphans
            };
            for path in orphans {
                let _ = std::fs::remove_file(path);
            }
            let _ = self.0.refresh(true);
            return reply.ok();
        }

        // Fisier care exista doar aici (de exemplu temporarul unui editor, redenumit
        // la numele final): se muta local si, daca numele nou nu este temporar, se urca.
        let orphans = {
            let mut tree = self.0.tree();
            let orphans = tree.rename(&node.path, &to);
            if let Some(n) = tree.nodes.get_mut(&ino) {
                n.local_only = ignored(newname);
                if !n.local_only {
                    n.dirty = true;
                    n.version = target_version;
                }
            }
            orphans
        };
        for path in orphans {
            let _ = std::fs::remove_file(path);
        }
        if self.0.open_count(ino) == 0 {
            if self.0.upload(ino).is_err() {
                return reply.error(Errno::EIO);
            }
            self.0.settle(ino);
        }
        reply.ok();
    }

    fn statfs(&self, _req: &Request, _ino: INodeNo, reply: ReplyStatfs) {
        // Spatiul real este cel de pe server; raportam mult, ca programele sa nu refuze scrierea.
        let blocks = 1u64 << 28; // 1 TiB in blocuri de 4 KiB
        reply.statfs(blocks, blocks, blocks, 1 << 20, 1 << 20, 4096, 255, 4096);
    }
}

impl Drive {
    /// Schimba marimea unui fisier (trunchiere sau extindere).
    fn truncate(&self, ino: u64, fh: Option<u64>, size: u64) -> Result<(), Errno> {
        let path = self.0.stage(ino, size == 0)?;
        File::options().write(true).open(&path).and_then(|f| f.set_len(size)).map_err(io_error)?;
        if let Some(fh) = fh {
            // Handle-ul trebuie sa lucreze de acum pe fisierul local.
            let file = File::options().read(true).write(true).open(&path).map_err(io_error)?;
            if let Some(handle) = self.0.handles().get_mut(&fh) {
                handle.file = Some(file);
                handle.staged = true;
            }
        }
        if let Some(node) = self.0.tree().nodes.get_mut(&ino) {
            node.size = size;
            node.mtime = now();
            node.dirty = true;
        }
        Ok(())
    }
}

/// Monteaza discul virtual si ramane pornit pana la Ctrl+C sau pana la demontare.
pub fn mount(api: Api, home: &Path, mountpoint: &Path, cache_limit: u64, host: String, log: fn(&str)) -> Result<(), String> {
    let (cache, staging) = (home.join("cache"), home.join("staging"));
    for dir in [&cache, &staging] {
        std::fs::create_dir_all(dir).map_err(|e| format!("nu pot crea {}: {e}", dir.display()))?;
    }
    // Ce a ramas neurcat de la o oprire brusca nu se pierde: este pus deoparte.
    let leftovers: Vec<PathBuf> = std::fs::read_dir(&staging)
        .map(|entries| entries.flatten().map(|e| e.path()).collect())
        .unwrap_or_default();
    if !leftovers.is_empty() {
        let recovered = home.join("recovered").join(format!("{}", now()));
        std::fs::create_dir_all(&recovered).map_err(|e| e.to_string())?;
        for path in &leftovers {
            if let Some(name) = path.file_name() {
                let _ = std::fs::rename(path, recovered.join(name));
            }
        }
        log(&format!(
            "ATENTIE: {} fisiere scrise si neurcate la oprirea anterioara au fost puse in {}",
            leftovers.len(),
            recovered.display()
        ));
    }
    if let Ok(entries) = std::fs::read_dir(&cache) {
        for entry in entries.flatten() {
            if entry.file_name().to_string_lossy().starts_with(".part-") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    std::fs::create_dir_all(mountpoint).map_err(|e| format!("nu pot crea {}: {e}", mountpoint.display()))?;

    let shared = Arc::new(Shared {
        api,
        tree: Mutex::new(Tree::new()),
        handles: Mutex::new(HashMap::new()),
        next_fh: AtomicU64::new(1),
        counter: AtomicU64::new(0),
        cache,
        staging,
        cache_limit,
        // SAFETY: getuid si getgid nu au conditii si nu pot esua.
        uid: unsafe { libc::getuid() },
        gid: unsafe { libc::getgid() },
        host,
        log,
    });
    shared.refresh(true).map_err(|e| format!("nu pot citi lista de fisiere de pe server: {e}"))?;

    let mut config = fuser::Config::default();
    // Mai multe fire de lucru sunt posibile doar pe Linux.
    config.n_threads = Some(if cfg!(target_os = "linux") { 4 } else { 1 });
    // Pe macOS montam direct prin unealta macFUSE; pe Linux, prin biblioteca
    // (FILESYNC_DIRECT_MOUNT=1 alege si acolo calea directa, pentru incercari).
    let direct = cfg!(target_os = "macos") || std::env::var("FILESYNC_DIRECT_MOUNT").is_ok();
    let failed = |e: std::io::Error| format!("nu pot monta la {}: {e}", mountpoint.display());
    let session = if direct {
        let device = helper_mount(mountpoint, log)?;
        fuser::Session::from_fd(Drive(shared.clone()), device, fuser::SessionACL::Owner, config)
            .and_then(|session| session.spawn())
            .map_err(failed)?
    } else {
        config.mount_options.extend([MountOption::FSName("filesync".into())]);
        fuser::spawn_mount(Drive(shared.clone()), mountpoint, &config).map_err(failed)?
    };
    log(&format!("Montat la {}. Ctrl+C demonteaza.", mountpoint.display()));

    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    ctrlc::set_handler(move || flag.store(true, Ordering::SeqCst)).map_err(|e| e.to_string())?;
    let mut last_retry = Instant::now();
    while !stop.load(Ordering::SeqCst) && !session.guard.is_finished() {
        std::thread::sleep(Duration::from_millis(300));
        if last_retry.elapsed() > Duration::from_secs(20) {
            let _ = shared.refresh(true);
            shared.retry_pending();
            last_retry = Instant::now();
        }
    }
    shared.retry_pending();
    let pending = shared.tree().nodes.values().filter(|n| n.dirty && !n.local_only && !n.dir).count();
    if pending > 0 {
        log(&format!("ATENTIE: {pending} fisiere nu au putut fi urcate; raman in {}", home.join("staging").display()));
    }
    if session.guard.is_finished() {
        let _ = session.join();
    } else if direct {
        if !unmount(mountpoint) {
            return Err(format!(
                "nu am putut demonta {} (este folosit de un program?). Inchide ce il foloseste si ruleaza: umount {}",
                mountpoint.display(),
                mountpoint.display()
            ));
        }
        let _ = session.join();
    } else {
        session.umount_and_join().map_err(|e| format!("demontare: {e}"))?;
    }
    log("Demontat.");
    Ok(())
}

/// Monteaza prin unealta sistemului (mount_macfuse pe macOS, fusermount3 pe Linux),
/// fara biblioteca libfuse. Unealta deschide dispozitivul FUSE si ni-l trimite
/// printr-un socket; de acolo vorbim direct cu nucleul.
fn helper_mount(mountpoint: &Path, log: fn(&str)) -> Result<OwnedFd, String> {
    let (local, remote) = socket_pair().map_err(|e| format!("socketpair: {e}"))?;
    let mut command = if cfg!(target_os = "macos") {
        let exe = std::env::current_exe().unwrap_or_default();
        let mut command = Command::new("/Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse");
        command
            .arg("-o")
            .arg("fsname=filesync,volname=filesync,noappledouble")
            .arg(mountpoint)
            .env("_FUSE_CALL_BY_LIB", "")
            .env("_FUSE_DAEMON_PATH", &exe)
            .env("_FUSE_COMMVERS", "2")
            .env("MOUNT_OSXFUSE_CALL_BY_LIB", "")
            .env("MOUNT_OSXFUSE_DAEMON_PATH", &exe);
        command
    } else {
        let mut command = Command::new("fusermount3");
        command.arg("-o").arg("rw,nosuid,nodev,fsname=filesync").arg("--").arg(mountpoint);
        command
    };
    // Capatul `remote` este mostenit de unealta; ii spunem numarul lui.
    command.env("_FUSE_COMMFD", remote.as_raw_fd().to_string()).stdin(Stdio::null());
    let mut child = command
        .spawn()
        .map_err(|e| format!("nu pot porni unealta de montare ({:?}): {e}", command.get_program()))?;
    drop(remote);

    let device = match receive_fd(&local) {
        Ok(device) => device,
        Err(e) => {
            let status = child.wait().map(|s| s.to_string()).unwrap_or_default();
            return Err(format!(
                "unealta de montare nu a reusit ({e}; {status}). Mesajul ei, daca exista, este mai sus."
            ));
        }
    };
    // Unealta se incheie abia dupa ce montarea este completa; o asteptam in fundal.
    std::thread::spawn(move || match child.wait() {
        Ok(status) if status.success() => {}
        Ok(status) => log(&format!("ATENTIE: unealta de montare s-a incheiat cu {status}")),
        Err(e) => log(&format!("ATENTIE: unealta de montare: {e}")),
    });
    Ok(device)
}

fn socket_pair() -> std::io::Result<(OwnedFd, OwnedFd)> {
    let mut fds: [libc::c_int; 2] = [0; 2];
    // SAFETY: `fds` are loc pentru cei doi descriptori pe care ii scrie socketpair.
    if unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: descriptorii tocmai au fost creati si nu apartin nimanui altcuiva.
    let (local, remote) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    // Capatul nostru nu trebuie mostenit de unealta.
    // SAFETY: fcntl pe un descriptor valid.
    unsafe { libc::fcntl(local.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
    Ok((local, remote))
}

/// Primeste un descriptor de fisier trimis prin socket (SCM_RIGHTS).
fn receive_fd(socket: &OwnedFd) -> std::io::Result<OwnedFd> {
    let mut data = [0u8; 64];
    let mut iov = libc::iovec { iov_base: data.as_mut_ptr().cast(), iov_len: data.len() };
    // SAFETY: CMSG_SPACE doar calculeaza o marime.
    let space = unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) } as usize;
    let mut control = vec![0u8; space];
    // SAFETY: msghdr este o structura simpla; zero este o valoare valida pentru toate campurile.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = space as _;
    loop {
        // SAFETY: `message` indica spre zone de memorie valide, care traiesc pe durata apelului.
        let received = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut message, 0) };
        if received < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if received == 0 {
            return Err(std::io::Error::other("nu a trimis dispozitivul FUSE"));
        }
        break;
    }
    // SAFETY: antetul de control, daca exista, se afla in `control`, care este inca valid.
    let fd = unsafe {
        let header = libc::CMSG_FIRSTHDR(&message);
        if header.is_null()
            || (*header).cmsg_level != libc::SOL_SOCKET
            || (*header).cmsg_type != libc::SCM_RIGHTS
        {
            return Err(std::io::Error::other("raspuns neasteptat de la unealta de montare"));
        }
        std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<RawFd>())
    };
    // SAFETY: descriptorul tocmai a fost primit si ne apartine; fcntl pe un descriptor valid.
    unsafe {
        libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        Ok(OwnedFd::from_raw_fd(fd))
    }
}

/// Demonteaza un disc montat pe calea directa.
fn unmount(mountpoint: &Path) -> bool {
    let attempts: &[(&str, &[&str])] = if cfg!(target_os = "macos") {
        &[("umount", &[]), ("diskutil", &["unmount", "force"])]
    } else {
        &[("fusermount3", &["-u"])]
    };
    attempts.iter().any(|(program, args)| {
        Command::new(program)
            .args(*args)
            .arg(mountpoint)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    })
}
FILESYNC_EOF
cargo build -p filesync-client && echo "=== compilat cu succes ==="
