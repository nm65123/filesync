//! Notificari de la sistem cand se schimba ceva intr-un director (inotify pe Linux,
//! FSEvents pe macOS, ReadDirectoryChangesW pe Windows), prin crate-ul `notify`.
//! Nu spun exact ce s-a schimbat (asta afla scanarea), doar ca merita o scanare acum.

use crate::scan::ignored;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::path::Path;
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::time::{Duration, Instant};

pub struct Watch {
    _watcher: RecommendedWatcher,
    events: Receiver<()>,
}

/// De ce s-a terminat asteptarea.
#[derive(PartialEq, Debug)]
pub enum Wake {
    /// S-a schimbat ceva in director (si s-a linistit).
    Changed,
    /// A trecut timpul fara schimbari.
    Timeout,
    /// S-a cerut oprirea.
    Stop,
}

impl Watch {
    pub fn new(dir: &Path) -> Result<Watch, String> {
        let (tx, events) = channel();
        let mut watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            let Ok(event) = result else { return };
            // Fisierele temporare ale editoarelor nu merita o scanare.
            let relevant = event.paths.is_empty()
                || event.paths.iter().any(|p| !p.file_name().and_then(|n| n.to_str()).is_some_and(ignored));
            if relevant {
                let _ = tx.send(());
            }
        })
        .map_err(|e| e.to_string())?;
        watcher.watch(dir, RecursiveMode::Recursive).map_err(|e| e.to_string())?;
        Ok(Watch { _watcher: watcher, events })
    }

    /// Asteapta cel mult `max` o schimbare. Dupa prima, mai asteapta pana trece o secunda
    /// fara alte schimbari (dar nu mai mult de 5 secunde in total), ca sa nu scanam in
    /// timpul unei copieri. `stop` este intrebat la fiecare 200 ms.
    pub fn wait(&self, max: Duration, stop: &dyn Fn() -> bool) -> Wake {
        let deadline = Instant::now() + max;
        let mut changed_at: Option<Instant> = None;
        let mut last_event = Instant::now();
        loop {
            if stop() {
                return Wake::Stop;
            }
            let now = Instant::now();
            if let Some(first) = changed_at {
                if last_event.elapsed() >= Duration::from_secs(1) || first.elapsed() >= Duration::from_secs(5) {
                    return Wake::Changed;
                }
            } else if now >= deadline {
                return Wake::Timeout;
            }
            match self.events.recv_timeout(Duration::from_millis(200)) {
                Ok(()) => {
                    last_event = Instant::now();
                    changed_at.get_or_insert(last_event);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return Wake::Timeout,
            }
        }
    }
}

/// Asteptare fara notificari (cand nu se pot porni): doar timpul si oprirea.
pub fn sleep(max: Duration, stop: &dyn Fn() -> bool) -> Wake {
    let deadline = Instant::now() + max;
    while Instant::now() < deadline {
        if stop() {
            return Wake::Stop;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Wake::Timeout
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wakes_on_change_and_times_out_otherwise() {
        let dir = std::env::temp_dir().join(format!("filesync-watch-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let watch = Watch::new(&dir).unwrap();
        let never = || false;
        assert_eq!(watch.wait(Duration::from_millis(600), &never), Wake::Timeout);
        let path = dir.join("a.txt");
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            std::fs::write(path, b"salut").unwrap();
        });
        let started = Instant::now();
        assert_eq!(watch.wait(Duration::from_secs(10), &never), Wake::Changed);
        assert!(started.elapsed() < Duration::from_secs(5));
        // Un fisier temporar nu trezeste.
        std::fs::write(dir.join("x.tmp"), b"nu").unwrap();
        assert_eq!(watch.wait(Duration::from_millis(600), &never), Wake::Timeout);
        assert_eq!(watch.wait(Duration::from_secs(10), &|| true), Wake::Stop);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
