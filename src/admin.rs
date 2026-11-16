use crate::index;
use crate::share;
use crate::util::{hash_password, human, parse_size, random_hex, valid_name};
use sqlx::PgPool;
use std::path::Path;

type Res<T> = Result<T, Box<dyn std::error::Error>>;

pub const HELP: &str = "\
filesync                          porneste serverul
filesync adduser <nume>           creeaza un utilizator (cere parola)
filesync passwd <nume>            schimba parola
filesync users                    listeaza utilizatorii
filesync quota <nume> <marime>    cota: 10G, 500M, 1T sau none (nelimitat)
filesync email <nume> <adresa>    adresa de e-mail (none = fara)
filesync group <nume> <grup>      grupul (none = fara)
filesync admin <nume> on|off      drept de administrator
filesync disable <nume>           dezactiveaza contul
filesync enable <nume>            reactiveaza contul
filesync addtoken <nume>          creeaza un token (parola de aplicatie)
filesync tokens <nume>            listeaza tokenurile
filesync deltoken <nume> <id|all> sterge un token sau pe toate
filesync reindex [nume]           reface indexul dupa ce este pe disc
filesync share <nume> <cale> [--days N] [--password]
                                  creeaza un link public catre un fisier sau director
filesync shares [nume]            listeaza linkurile
filesync unshare <cod>            sterge un link
filesync gencert <nume|ip>... [--force]
                                  genereaza un certificat self-signed
filesync help                     acest text";

fn arg<'a>(args: &'a [String], index: usize, what: &str) -> Res<&'a str> {
    args.get(index)
        .map(String::as_str)
        .ok_or_else(|| format!("lipseste: {what}").into())
}

fn none_or(value: &str) -> Option<&str> {
    (!matches!(value, "none" | "-" | "")).then_some(value)
}

/// Comenzi care nu au nevoie de baza de date. Intoarce true daca a rulat una.
pub fn local(data: &Path, args: &[String]) -> Res<bool> {
    match args.first().map(String::as_str) {
        Some("help" | "--help" | "-h") => println!("{HELP}"),
        Some("gencert") => gencert(data, &args[1..])?,
        _ => return Ok(false),
    }
    Ok(true)
}

/// Comenzi de administrare. Intoarce true daca a rulat una, false daca trebuie pornit serverul.
pub async fn run(pool: &PgPool, data: &Path, args: &[String]) -> Res<bool> {
    let Some(command) = args.first().map(String::as_str) else {
        return Ok(false);
    };
    match command {
        "adduser" => {
            let name = arg(args, 1, "numele")?;
            if !valid_name(name) {
                return Err("nume invalid: doar litere mici, cifre, punct, - si _".into());
            }
            let hash = read_password(name)?;
            let done = sqlx::query(
                "INSERT INTO users (name, password) VALUES ($1, $2) ON CONFLICT (name) DO NOTHING",
            )
            .bind(name)
            .bind(&hash)
            .execute(pool)
            .await?;
            if done.rows_affected() == 0 {
                return Err(format!("utilizatorul {name} exista deja (foloseste passwd)").into());
            }
            eprintln!("utilizator creat: {name}");
        }
        "passwd" => {
            let name = arg(args, 1, "numele")?;
            let hash = read_password(name)?;
            let done = sqlx::query("UPDATE users SET password = $2 WHERE name = $1")
                .bind(name)
                .bind(&hash)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "users" => list_users(pool).await?,
        "share" => {
            let name = arg(args, 1, "numele")?;
            let path = arg(args, 2, "calea fisierului sau a directorului")?;
            let mut days = None;
            let mut password = None;
            let mut rest = args[3..].iter();
            while let Some(option) = rest.next() {
                match option.as_str() {
                    "--days" => {
                        let value = rest.next().ok_or("--days are nevoie de un numar")?;
                        days = Some(value.parse::<i64>().map_err(|_| "--days are nevoie de un numar")?);
                    }
                    "--password" => {
                        eprint!("parola pentru link: ");
                        let mut line = String::new();
                        std::io::stdin().read_line(&mut line)?;
                        let line = line.trim_end_matches(['\r', '\n']).to_string();
                        if line.is_empty() {
                            return Err("parola nu poate fi goala".into());
                        }
                        password = Some(line);
                    }
                    other => return Err(format!("optiune necunoscuta: {other}").into()),
                }
            }
            let (id,) = sqlx::query_as::<_, (i32,)>("SELECT id FROM users WHERE name = $1")
                .bind(name)
                .fetch_optional(pool)
                .await?
                .ok_or_else(|| format!("utilizator inexistent: {name}"))?;
            let (token, path, expires) =
                share::new_share(pool, data, id, name, path, password.as_deref(), days)
                    .await
                    .map_err(|(_, message)| message)?;
            eprintln!(
                "link creat pentru {name}:{path}{}{}",
                if password.is_some() { ", cu parola" } else { "" },
                match (days, expires) {
                    (Some(days), Some(_)) => format!(", expira in {days} zile"),
                    _ => ", fara expirare".to_string(),
                }
            );
            println!("{}", link(&token));
        }
        "shares" => {
            let only = args.get(1).map(String::as_str);
            let rows = sqlx::query_as::<_, (String, String, String, Option<String>, bool, i64)>(
                "SELECT s.token, u.name, s.path, to_char(s.expires, 'YYYY-MM-DD HH24:MI'),
                        s.password IS NOT NULL, s.downloads
                 FROM shares s JOIN users u ON u.id = s.owner
                 WHERE $1::text IS NULL OR u.name = $1
                 ORDER BY u.name, s.created",
            )
            .bind(only)
            .fetch_all(pool)
            .await?;
            println!(
                "{:<32} {:<16} {:<17} {:<6} {:>9}  {}",
                "COD", "UTILIZATOR", "EXPIRA", "PAROLA", "DESCARCAT", "CALE"
            );
            for (token, name, path, expires, password, downloads) in rows {
                println!(
                    "{:<32} {:<16} {:<17} {:<6} {:>9}  {}",
                    token,
                    name,
                    expires.as_deref().unwrap_or("niciodata"),
                    if password { "da" } else { "nu" },
                    downloads,
                    path
                );
            }
        }
        "unshare" => {
            let token = arg(args, 1, "codul linkului")?;
            let done = sqlx::query("DELETE FROM shares WHERE token = $1")
                .bind(token)
                .execute(pool)
                .await?;
            if done.rows_affected() == 0 {
                return Err(format!("link inexistent: {token}").into());
            }
            eprintln!("link sters");
        }
        "reindex" => {
            let only = args.get(1).map(String::as_str);
            let users = sqlx::query_as::<_, (i32, String)>("SELECT id, name FROM users ORDER BY name")
                .fetch_all(pool)
                .await?;
            if let Some(name) = only {
                if !users.iter().any(|(_, n)| n == name) {
                    return Err(format!("utilizator inexistent: {name}").into());
                }
            }
            for (id, name) in users.into_iter().filter(|(_, n)| only.is_none_or(|o| o == n)) {
                let root = data.join("files").join(&name);
                let stats = index::sync(pool, &root, id, "").await.map_err(|e| e.to_string())?;
                println!(
                    "{name}: {} noi, {} modificate, {} disparute",
                    stats.added, stats.updated, stats.removed
                );
            }
        }
        "quota" => {
            let name = arg(args, 1, "numele")?;
            let quota = parse_size(arg(args, 2, "marimea (ex. 10G sau none)")?)
                .ok_or("marime invalida: foloseste 10G, 500M, 1T sau none")?;
            let done = sqlx::query("UPDATE users SET quota = $2 WHERE name = $1")
                .bind(name)
                .bind(quota)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "email" => {
            let name = arg(args, 1, "numele")?;
            let email = none_or(arg(args, 2, "adresa")?);
            let done = sqlx::query("UPDATE users SET email = $2 WHERE name = $1")
                .bind(name)
                .bind(email)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "group" => {
            let name = arg(args, 1, "numele")?;
            let group = none_or(arg(args, 2, "grupul")?);
            let done = sqlx::query("UPDATE users SET grp = $2 WHERE name = $1")
                .bind(name)
                .bind(group)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "admin" => {
            let name = arg(args, 1, "numele")?;
            let on = match arg(args, 2, "on sau off")? {
                "on" => true,
                "off" => false,
                _ => return Err("foloseste on sau off".into()),
            };
            let done = sqlx::query("UPDATE users SET admin = $2 WHERE name = $1")
                .bind(name)
                .bind(on)
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "disable" | "enable" => {
            let name = arg(args, 1, "numele")?;
            let done = sqlx::query("UPDATE users SET active = $2 WHERE name = $1")
                .bind(name)
                .bind(command == "enable")
                .execute(pool)
                .await?;
            changed(done.rows_affected(), name)?;
        }
        "addtoken" => {
            let name = arg(args, 1, "numele")?;
            let token = random_hex()?;
            let hash = blake3::hash(token.as_bytes()).to_hex().to_string();
            let done = sqlx::query(
                "INSERT INTO tokens (hash, user_id) SELECT $1, id FROM users WHERE name = $2",
            )
            .bind(&hash)
            .bind(name)
            .execute(pool)
            .await?;
            if done.rows_affected() == 0 {
                return Err(format!("utilizator inexistent: {name}").into());
            }
            eprintln!("token creat, id {}", &hash[..8]);
            println!("{token}");
        }
        "tokens" => {
            let name = arg(args, 1, "numele")?;
            let rows = sqlx::query_as::<_, (String, String)>(
                "SELECT left(t.hash, 8), to_char(t.created, 'YYYY-MM-DD HH24:MI')
                 FROM tokens t JOIN users u ON u.id = t.user_id
                 WHERE u.name = $1 ORDER BY t.created",
            )
            .bind(name)
            .fetch_all(pool)
            .await?;
            for (id, created) in &rows {
                println!("{id}  {created}");
            }
            eprintln!("{} token(uri) pentru {name}", rows.len());
        }
        "deltoken" => {
            let name = arg(args, 1, "numele")?;
            let id = arg(args, 2, "id-ul tokenului sau all")?;
            let prefix = if id == "all" { "" } else { id };
            let done = sqlx::query(
                "DELETE FROM tokens
                 WHERE user_id = (SELECT id FROM users WHERE name = $1)
                   AND left(hash, length($2)) = $2",
            )
            .bind(name)
            .bind(prefix)
            .execute(pool)
            .await?;
            eprintln!("{} token(uri) sterse", done.rows_affected());
        }
        other => return Err(format!("comanda necunoscuta: {other}\n\n{HELP}").into()),
    }
    Ok(true)
}

fn changed(rows: u64, name: &str) -> Res<()> {
    if rows == 0 {
        return Err(format!("utilizator inexistent: {name}").into());
    }
    eprintln!("salvat: {name}");
    Ok(())
}

fn read_password(name: &str) -> Res<String> {
    eprint!("parola pentru {name}: ");
    let mut password = String::new();
    std::io::stdin().read_line(&mut password)?;
    let password = password.trim_end_matches(['\r', '\n']);
    if password.len() < 8 {
        return Err("parola trebuie sa aiba cel putin 8 caractere".into());
    }
    Ok(hash_password(password)?)
}

/// Adresa completa a unui link, daca stim sub ce adresa este vazut serverul.
fn link(token: &str) -> String {
    let base = std::env::var("FILESYNC_URL")
        .ok()
        .map(|url| url.trim_end_matches('/').to_string())
        .filter(|url| !url.is_empty())
        .or_else(|| {
            let listen: std::net::SocketAddr = std::env::var("FILESYNC_LISTEN").ok()?.parse().ok()?;
            (!listen.ip().is_unspecified()).then(|| format!("https://{listen}"))
        });
    match base {
        Some(base) => format!("{base}/s/{token}"),
        None => {
            eprintln!("(seteaza FILESYNC_URL ca sa primesti adresa completa)");
            format!("/s/{token}")
        }
    }
}

async fn list_users(pool: &PgPool) -> Res<()> {
    let rows = sqlx::query_as::<_, (String, Option<String>, Option<String>, Option<i64>, bool, bool, i64, i64)>(
        "SELECT u.name, u.email, u.grp, u.quota, u.admin, u.active,
                (SELECT count(*) FROM tokens t WHERE t.user_id = u.id),
                (SELECT COALESCE(SUM(f.size), 0)::bigint FROM files f
                 WHERE f.owner = u.id AND NOT f.deleted)
         FROM users u ORDER BY u.name",
    )
    .fetch_all(pool)
    .await?;
    println!(
        "{:<20} {:<28} {:<12} {:>10} {:>10} {:<5} {:<6} {}",
        "NUME", "EMAIL", "GRUP", "FOLOSIT", "COTA", "ADMIN", "ACTIV", "TOKENURI"
    );
    for (name, email, group, quota, admin, active, tokens, used) in rows {
        println!(
            "{:<20} {:<28} {:<12} {:>10} {:>10} {:<5} {:<6} {}",
            name,
            email.as_deref().unwrap_or("-"),
            group.as_deref().unwrap_or("-"),
            human(used as u64),
            quota.map(|q| human(q as u64)).unwrap_or_else(|| "nelimitat".into()),
            if admin { "da" } else { "nu" },
            if active { "da" } else { "nu" },
            tokens
        );
    }
    Ok(())
}

/// Certificat self-signed pentru numele si adresele IP date, cu ajutorul `openssl`.
fn gencert(data: &Path, args: &[String]) -> Res<()> {
    let force = args.iter().any(|a| a == "--force");
    let names: Vec<&String> = args.iter().filter(|a| *a != "--force").collect();
    if names.is_empty() {
        return Err("gencert: da cel putin un nume sau o adresa IP".into());
    }
    let dir = data.join("tls");
    std::fs::create_dir_all(&dir)?;
    let cert = dir.join("cert.pem");
    let key = dir.join("key.pem");
    if cert.exists() && !force {
        return Err(format!(
            "exista deja un certificat: {}\n\
             Unul nou il inlocuieste, iar toate calculatoarele care l-au instalat pe cel \
             actual vor trebui sa il instaleze pe cel nou. Daca asta vrei, adauga --force.",
            cert.display()
        )
        .into());
    }
    let san = names
        .iter()
        .map(|n| match n.parse::<std::net::IpAddr>() {
            Ok(_) => format!("IP:{n}"),
            Err(_) => format!("DNS:{n}"),
        })
        .collect::<Vec<_>>()
        .join(",");

    let status = std::process::Command::new("openssl")
        .args(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"])
        .args(["-nodes", "-days", "825", "-subj"])
        .arg(format!("/CN={}", names[0]))
        .arg("-addext")
        .arg(format!("subjectAltName={san}"))
        .arg("-addext")
        .arg("extendedKeyUsage=serverAuth")
        .arg("-keyout")
        .arg(&key)
        .arg("-out")
        .arg(&cert)
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| format!("nu pot rula openssl (este instalat?): {e}"))?;
    if !status.success() {
        return Err("openssl a esuat".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600))?;
    }

    println!("certificat: {}", cert.display());
    println!("cheie:      {}", key.display());
    println!("valabil pentru: {san} (825 de zile)");
    let _ = std::process::Command::new("openssl")
        .args(["x509", "-noout", "-fingerprint", "-sha256", "-in"])
        .arg(&cert)
        .status();
    println!("Serverul il foloseste automat la urmatoarea pornire.");
    Ok(())
}
