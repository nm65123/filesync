//! Legatura cu serverul filesync (HTTPS).

use base64::Engine;
use serde::Deserialize;
use std::io::Read;
use std::path::Path;
use std::time::Duration;

#[derive(Deserialize, Clone, Debug)]
pub struct Entry {
    pub path: String,
    pub dir: bool,
    pub size: u64,
    pub hash: String,
    pub mtime: i64,
    pub version: i64,
    pub deleted: bool,
}

#[derive(Deserialize)]
struct ChangesReply {
    cursor: i64,
    more: bool,
    entries: Vec<Entry>,
}

#[derive(Debug)]
pub enum Fail {
    /// Pe server este alta versiune decat cea pe care o stiam (se rezolva la trecerea urmatoare).
    Conflict,
    /// Serverul a refuzat (cota depasita, cale invalida...). Textul este mesajul serverului.
    Refused(String),
    /// Reteaua sau serverul nu raspund.
    Network(String),
}

impl std::fmt::Display for Fail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Fail::Conflict => write!(f, "versiune schimbata pe server"),
            Fail::Refused(m) => write!(f, "refuzat de server: {m}"),
            Fail::Network(m) => write!(f, "retea: {m}"),
        }
    }
}

pub struct Api {
    agent: ureq::Agent,
    base: String,
    auth: String,
}

/// Citeste si calculeaza hash-ul a ceea ce trece prin el.
struct Hashing<R> {
    inner: R,
    hasher: blake3::Hasher,
}

impl<R: Read> Read for Hashing<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.hasher.update(&buf[..n]);
        Ok(n)
    }
}

/// Codifica o cale pentru adresa: fiecare segment separat, "/" ramane.
fn encode(path: &str) -> String {
    let mut out = String::new();
    for byte in path.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn network(e: ureq::Error) -> Fail {
    Fail::Network(e.to_string())
}

impl Api {
    pub fn new(url: &str, user: &str, token: &str, ca_cert: Option<&Path>) -> Result<Api, String> {
        let mut tls = ureq::tls::TlsConfig::builder();
        if let Some(path) = ca_cert {
            let pem = std::fs::read(path)
                .map_err(|e| format!("nu pot citi certificatul {}: {e}", path.display()))?;
            let cert = ureq::tls::Certificate::from_pem(&pem)
                .map_err(|e| format!("certificat invalid ({}): {e}", path.display()))?;
            tls = tls.root_certs(ureq::tls::RootCerts::new_with_certs(&[cert]));
        }
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(20)))
            .timeout_recv_response(Some(Duration::from_secs(120)))
            .tls_config(tls.build())
            .build()
            .into();
        let credentials = base64::engine::general_purpose::STANDARD.encode(format!("{user}:{token}"));
        Ok(Api {
            agent,
            base: url.trim_end_matches('/').to_string(),
            auth: format!("Basic {credentials}"),
        })
    }

    /// Mesajul de eroare al serverului, pentru raspunsurile care nu sunt 2xx.
    fn refused(mut response: ureq::http::Response<ureq::Body>) -> Fail {
        let status = response.status().as_u16();
        let body = response.body_mut().read_to_string().unwrap_or_default();
        match status {
            412 => Fail::Conflict,
            401 => Fail::Refused("utilizator sau token gresit".into()),
            _ => Fail::Refused(format!("{status} {}", body.trim())),
        }
    }

    /// Tot ce s-a schimbat pe server dupa `since`. Intoarce si noul cursor.
    pub fn changes(&self, since: i64) -> Result<(Vec<Entry>, i64), Fail> {
        let mut cursor = since;
        let mut all = Vec::new();
        loop {
            let url = format!("{}/api/changes?since={cursor}&limit=5000", self.base);
            let mut response = self
                .agent
                .get(&url)
                .header("Authorization", &self.auth)
                .call()
                .map_err(network)?;
            if !response.status().is_success() {
                return Err(Self::refused(response));
            }
            let text = response
                .body_mut()
                .with_config()
                .limit(512 * 1024 * 1024)
                .read_to_string()
                .map_err(network)?;
            let reply: ChangesReply =
                serde_json::from_str(&text).map_err(|e| Fail::Network(format!("raspuns invalid: {e}")))?;
            cursor = reply.cursor;
            all.extend(reply.entries);
            if !reply.more {
                return Ok((all, cursor));
            }
        }
    }

    /// Descarca un fisier in `dest`. Intoarce hash-ul continutului primit.
    pub fn download(&self, path: &str, dest: &Path) -> Result<String, Fail> {
        let url = format!("{}/files/{}", self.base, encode(path));
        let mut response = self
            .agent
            .get(&url)
            .header("Authorization", &self.auth)
            .call()
            .map_err(network)?;
        if !response.status().is_success() {
            return Err(Self::refused(response));
        }
        let mut reader = Hashing { inner: response.body_mut().as_reader(), hasher: blake3::Hasher::new() };
        let mut file = std::fs::File::create(dest).map_err(|e| Fail::Network(e.to_string()))?;
        std::io::copy(&mut reader, &mut file).map_err(|e| Fail::Network(e.to_string()))?;
        file.sync_all().map_err(|e| Fail::Network(e.to_string()))?;
        Ok(reader.hasher.finalize().to_hex().to_string())
    }

    /// Urca un fisier. `if_version` este versiunea pe care o stim pe server (0 = nu exista).
    /// Intoarce (versiunea noua, hash-ul continutului trimis).
    pub fn upload(
        &self,
        path: &str,
        source: &Path,
        size: u64,
        mtime: i64,
        if_version: i64,
    ) -> Result<(i64, String), Fail> {
        let url = format!("{}/files/{}", self.base, encode(path));
        let file = std::fs::File::open(source).map_err(|e| Fail::Network(e.to_string()))?;
        // Citim exact `size` octeti, cat am anuntat, chiar daca fisierul creste intre timp.
        let mut reader = Hashing { inner: file.take(size), hasher: blake3::Hasher::new() };
        let response = self
            .agent
            .put(&url)
            .header("Authorization", &self.auth)
            .header("Content-Length", &size.to_string())
            .header("X-OC-Mtime", &mtime.to_string())
            .header("X-Filesync-If-Version", &if_version.to_string())
            .send(ureq::SendBody::from_reader(&mut reader))
            .map_err(network)?;
        if !response.status().is_success() {
            return Err(Self::refused(response));
        }
        let version = response
            .headers()
            .get("x-filesync-version")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<i64>().ok())
            .ok_or_else(|| Fail::Network("serverul nu a trimis versiunea".into()))?;
        Ok((version, reader.hasher.finalize().to_hex().to_string()))
    }

    /// Sterge de pe server. Un director este sters doar daca este gol.
    /// Daca nu mai exista, este tot succes.
    pub fn delete(&self, path: &str, if_version: Option<i64>) -> Result<(), Fail> {
        let url = format!("{}/files/{}", self.base, encode(path));
        let mut request = self
            .agent
            .delete(&url)
            .header("Authorization", &self.auth)
            .header("X-Filesync-Only-Empty", "1");
        if let Some(version) = if_version {
            request = request.header("X-Filesync-If-Version", &version.to_string());
        }
        let response = request.call().map_err(network)?;
        match response.status().as_u16() {
            200..=299 | 404 => Ok(()),
            _ => Err(Self::refused(response)),
        }
    }

    /// Muta sau redenumeste pe server (un fisier existent la destinatie este inlocuit).
    pub fn rename(&self, from: &str, to: &str) -> Result<(), Fail> {
        let url = format!("{}/api/move", self.base);
        let body = serde_json::json!({ "from": from, "to": to }).to_string();
        let response = self
            .agent
            .post(&url)
            .header("Authorization", &self.auth)
            .header("Content-Type", "application/json")
            .send(body)
            .map_err(network)?;
        if !response.status().is_success() {
            return Err(Self::refused(response));
        }
        Ok(())
    }

    pub fn mkdir(&self, path: &str) -> Result<(), Fail> {
        let url = format!("{}/api/dirs/{}", self.base, encode(path));
        let response = self
            .agent
            .put(&url)
            .header("Authorization", &self.auth)
            .send_empty()
            .map_err(network)?;
        if !response.status().is_success() {
            return Err(Self::refused(response));
        }
        Ok(())
    }
}
