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
