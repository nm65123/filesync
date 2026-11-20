//! Interfata web: autentificare cu sesiune (cookie), pagina cu fisierele utilizatorului
//! (listare, descarcare, incarcare, director nou, redenumire, stergere, linkuri publice).
//! Pagina este una singura, cu HTML si JavaScript incluse aici, si foloseste aceleasi
//! API-uri ca clientul de sincronizare (/files, /api/dirs, /api/move, /api/shares).

use crate::http::{App, User, credentials, internal, text};
use crate::index;
use crate::util::random_hex;
use axum::{
    Form, Json, Router,
    extract::{Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{Html, IntoResponse, Redirect, Response},
    routing::get,
};
use serde::{Deserialize, Serialize};

const COOKIE: &str = "filesync_session";
/// O sesiune tine 30 de zile de la autentificare.
const SESSION_DAYS: i64 = 30;

pub fn routes() -> Router<App> {
    Router::new()
        .route("/", get(home))
        .route("/login", get(login_page).post(login))
        .route("/logout", axum::routing::post(logout))
        .route("/api/list", get(list))
        .route("/api/me", get(me))
}

/// Valoarea cookie-ului de sesiune din cerere, daca exista.
fn session_cookie(headers: &HeaderMap) -> Option<String> {
    let cookies = headers.get(header::COOKIE)?.to_str().ok()?;
    cookies.split(';').find_map(|part| {
        let (name, value) = part.trim().split_once('=')?;
        (name == COOKIE).then(|| value.to_string())
    })
}

/// Utilizatorul sesiunii din cookie: None daca nu exista un cookie valid.
pub async fn session_user(app: &App, headers: &HeaderMap) -> Result<Option<User>, Response> {
    let Some(token) = session_cookie(headers) else {
        return Ok(None);
    };
    if token.len() != 64 || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Ok(None);
    }
    let found = sqlx::query_as::<_, (i32, String, bool)>(
        "SELECT u.id, u.name, u.active FROM sessions s JOIN users u ON u.id = s.user_id
         WHERE s.token = $1 AND s.expires > now()",
    )
    .bind(&token)
    .fetch_optional(&app.pool)
    .await
    .map_err(internal)?;
    Ok(found.and_then(|(id, name, active)| active.then_some(User { id, name })))
}

fn cookie_header(app: &App, token: &str, max_age: i64) -> String {
    format!(
        "{COOKIE}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={max_age}{}",
        if app.tls { "; Secure" } else { "" }
    )
}

async fn home(State(app): State<App>, headers: HeaderMap) -> Result<Response, Response> {
    match session_user(&app, &headers).await? {
        Some(_) => Ok(Html(APP_PAGE.replacen("/*STYLE*/", STYLE, 1)).into_response()),
        None => Ok(Redirect::to("/login").into_response()),
    }
}

async fn login_page(State(app): State<App>, headers: HeaderMap) -> Result<Response, Response> {
    if session_user(&app, &headers).await?.is_some() {
        return Ok(Redirect::to("/").into_response());
    }
    Ok(Html(login_html("")).into_response())
}

#[derive(Deserialize)]
struct LoginForm {
    user: String,
    password: String,
}

async fn login(State(app): State<App>, Form(form): Form<LoginForm>) -> Result<Response, Response> {
    let user = match credentials(&app, form.user.trim(), &form.password).await {
        Ok(user) => user,
        Err(_) => {
            return Ok((
                StatusCode::UNAUTHORIZED,
                Html(login_html("Utilizator, parola sau token gresit.")),
            )
                .into_response());
        }
    };
    let token = random_hex().map_err(internal)?;
    let token = token[..64.min(token.len())].to_string();
    // Sesiunile vechi ale tuturor se curata cu ocazia asta.
    let _ = sqlx::query("DELETE FROM sessions WHERE expires < now()").execute(&app.pool).await;
    sqlx::query("INSERT INTO sessions (token, user_id, expires) VALUES ($1, $2, now() + make_interval(days => $3))")
        .bind(&token)
        .bind(user.id)
        .bind(SESSION_DAYS as i32)
        .execute(&app.pool)
        .await
        .map_err(internal)?;
    Ok((
        [(header::SET_COOKIE, cookie_header(&app, &token, SESSION_DAYS * 86_400))],
        Redirect::to("/"),
    )
        .into_response())
}

async fn logout(State(app): State<App>, headers: HeaderMap) -> Result<Response, Response> {
    if let Some(token) = session_cookie(&headers) {
        let _ = sqlx::query("DELETE FROM sessions WHERE token = $1").bind(&token).execute(&app.pool).await;
    }
    Ok(([(header::SET_COOKIE, cookie_header(&app, "", 0))], Redirect::to("/login")).into_response())
}

#[derive(Deserialize)]
struct ListQuery {
    #[serde(default)]
    path: String,
}

#[derive(Serialize)]
struct ListEntry {
    name: String,
    dir: bool,
    size: i64,
    mtime: i64,
    version: i64,
}

#[derive(Serialize)]
struct Listing {
    path: String,
    entries: Vec<ListEntry>,
}

/// Continutul direct al unui director, din index.
async fn list(
    State(app): State<App>,
    headers: HeaderMap,
    Query(query): Query<ListQuery>,
) -> Result<Json<Listing>, Response> {
    let user = crate::http::auth(&app, &headers).await?;
    let path = query.path.trim_matches('/').to_string();
    if !path.is_empty() {
        let exists = sqlx::query_as::<_, (bool,)>(
            "SELECT is_dir FROM files WHERE owner = $1 AND path = $2 AND NOT deleted",
        )
        .bind(user.id)
        .bind(&path)
        .fetch_optional(&app.pool)
        .await
        .map_err(internal)?;
        match exists {
            Some((true,)) => {}
            Some((false,)) => return Err(text(StatusCode::BAD_REQUEST, "Nu este director.")),
            None => return Err(text(StatusCode::NOT_FOUND, "Directorul nu exista.")),
        }
    }
    let rows = sqlx::query_as::<_, (String, bool, i64, i64, i64)>(
        "SELECT path, is_dir, size, extract(epoch from modified)::bigint, version
         FROM files
         WHERE owner = $1 AND NOT deleted
           AND ($2 = '' OR left(path, length($2) + 1) = $2 || '/')
           AND position('/' in CASE WHEN $2 = '' THEN path ELSE substr(path, length($2) + 2) END) = 0
         ORDER BY is_dir DESC, lower(path)",
    )
    .bind(user.id)
    .bind(&path)
    .fetch_all(&app.pool)
    .await
    .map_err(internal)?;
    let entries = rows
        .into_iter()
        .map(|(full, dir, size, mtime, version)| ListEntry {
            name: full.rsplit('/').next().unwrap_or(&full).to_string(),
            dir,
            size,
            mtime,
            version,
        })
        .collect();
    Ok(Json(Listing { path, entries }))
}

#[derive(Serialize)]
struct Me {
    name: String,
    used: i64,
    quota: Option<i64>,
}

async fn me(State(app): State<App>, headers: HeaderMap) -> Result<Json<Me>, Response> {
    let user = crate::http::auth(&app, &headers).await?;
    let (quota,) = sqlx::query_as::<_, (Option<i64>,)>("SELECT quota FROM users WHERE id = $1")
        .bind(user.id)
        .fetch_one(&app.pool)
        .await
        .map_err(internal)?;
    let used = index::used(&app.pool, user.id).await.map_err(internal)?;
    Ok(Json(Me { name: user.name, used, quota }))
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

const STYLE: &str = r#"
:root{color-scheme:light dark;--line:#8884;--muted:#888;--accent:#2563eb;--bg2:#8881}
*{box-sizing:border-box}
body{font:16px/1.5 system-ui,sans-serif;margin:0;padding:0}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
button,input[type=text],input[type=password],input[type=number]{font:inherit;padding:.4rem .7rem;border:1px solid var(--line);border-radius:.4rem;background:transparent;color:inherit}
button{cursor:pointer}button.primary{background:var(--accent);color:#fff;border-color:var(--accent)}
button:disabled{opacity:.5;cursor:default}
.wrap{max-width:64rem;margin:0 auto;padding:1rem}
.bar{display:flex;flex-wrap:wrap;gap:.5rem;align-items:center;margin:.5rem 0 1rem}
.bar .grow{flex:1}
.crumbs{overflow-wrap:anywhere}.crumbs span{color:var(--muted)}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:.45rem .6rem;border-bottom:1px solid var(--line);vertical-align:middle}
.n{white-space:nowrap;text-align:right;font-variant-numeric:tabular-nums;color:var(--muted)}
td.acts{white-space:nowrap;text-align:right}td.acts button{padding:.2rem .5rem;margin-left:.2rem;border:none;color:var(--accent)}
tr.drop{outline:2px dashed var(--accent)}
.muted{color:var(--muted)}.small{font-size:.9rem}
#drop{border:2px dashed transparent;border-radius:.6rem;padding:.2rem}
#drop.over{border-color:var(--accent);background:var(--bg2)}
#msg{min-height:1.5rem}
#shares td{word-break:break-all}
.login{max-width:22rem;margin:4rem auto;padding:1.5rem;border:1px solid var(--line);border-radius:.6rem}
.login label{display:block;margin:.6rem 0 .2rem}.login input{width:100%}
.err{color:#dc2626}
dialog{border:1px solid var(--line);border-radius:.6rem;padding:1rem;max-width:26rem}
dialog label{display:block;margin:.5rem 0 .2rem}dialog input{width:100%}
dialog .btns{display:flex;justify-content:flex-end;gap:.5rem;margin-top:1rem}
"#;

fn login_html(error: &str) -> String {
    let error = if error.is_empty() { String::new() } else { format!("<p class=\"err\">{}</p>", escape(error)) };
    format!(
        "<!doctype html>\n<html lang=\"ro\"><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
<meta name=\"robots\" content=\"noindex, nofollow\"><title>filesync</title><style>{STYLE}</style></head>\
<body><form class=\"login\" method=\"post\" action=\"/login\"><h1>filesync</h1>{error}\
<label for=\"user\">Utilizator</label><input id=\"user\" name=\"user\" type=\"text\" autocomplete=\"username\" autofocus required>\
<label for=\"password\">Parola sau token</label><input id=\"password\" name=\"password\" type=\"password\" autocomplete=\"current-password\" required>\
<p><button class=\"primary\" type=\"submit\">Intra</button></p></form></body></html>"
    )
}

const APP_PAGE: &str = concat!(
    r##"<!doctype html>
<html lang="ro"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>filesync</title><style>/*STYLE*/"##,
    r##"</style></head>
<body><div class="wrap">
<div class="bar"><strong>filesync</strong><span id="who" class="muted small"></span><span class="grow"></span>
<form method="post" action="/logout"><button type="submit">Iesire</button></form></div>
<div class="bar"><div class="crumbs grow" id="crumbs"></div>
<button id="btn-upload">Incarca fisiere</button><input id="file" type="file" multiple hidden>
<button id="btn-folder">Director nou</button><button id="btn-shares">Linkuri publice</button></div>
<div id="msg" class="small muted"></div>
<div id="drop"><table><thead><tr><th>Nume</th><th class="n">Marime</th><th class="n">Modificat</th><th></th></tr></thead>
<tbody id="rows"></tbody></table></div>
<p class="muted small">Trage fisiere aici ca sa le incarci. Click pe un fisier il descarca.</p>
<dialog id="dlg-share"><form method="dialog"><h3>Link public</h3><p id="share-what" class="small muted"></p>
<label>Parola (optional)</label><input id="share-pass" type="text" autocomplete="off">
<label>Expira in (zile; gol = niciodata)</label><input id="share-days" type="number" min="1">
<div class="btns"><button value="cancel">Renunta</button><button class="primary" value="ok">Creeaza</button></div></form></dialog>
<dialog id="dlg-shares"><h3>Linkurile mele publice</h3><table id="shares"><tbody></tbody></table>
<div class="btns"><button id="shares-close">Inchide</button></div></dialog>
</div>
<script>
"use strict";
const $=s=>document.querySelector(s);
const enc=p=>p.split("/").filter(Boolean).map(encodeURIComponent).join("/");
const esc=s=>s.replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
const human=n=>{const u=["B","KiB","MiB","GiB","TiB"];let i=0;while(n>=1024&&i<4){n/=1024;i++}return (i?n.toFixed(1):n)+" "+u[i]};
const when=s=>{if(!s)return"";const d=new Date(s*1000);const p=n=>String(n).padStart(2,"0");return d.getFullYear()+"-"+p(d.getMonth()+1)+"-"+p(d.getDate())+" "+p(d.getHours())+":"+p(d.getMinutes())};
let cur="";
function msg(t,err){const m=$("#msg");m.textContent=t;m.className="small "+(err?"err":"muted")}
async function api(url,opt={}){const r=await fetch(url,opt);if(r.status===401){location.href="/login";throw new Error("sesiune expirata")}
if(!r.ok){const t=(await r.text()).trim();throw new Error(t||("eroare "+r.status))}return r}
function path(){return decodeURIComponent(location.hash.replace(/^#\/?/,"")).replace(/\/+$/,"")}
function go(p){location.hash="#/"+enc(p)}
async function load(){cur=path();
 const c=$("#crumbs");let h='<a href="#/">Acasa</a>';let acc="";
 for(const part of cur.split("/").filter(Boolean)){acc+=(acc?"/":"")+part;h+=' <span>/</span> <a href="#/'+enc(acc)+'">'+esc(part)+'</a>'}
 c.innerHTML=h;
 let data;try{data=await (await api("/api/list?path="+encodeURIComponent(cur))).json()}catch(e){msg(e.message,true);if(cur){go("")}return}
 const rows=$("#rows");rows.innerHTML="";
 if(!data.entries.length){rows.innerHTML='<tr><td colspan="4" class="muted">Directorul este gol.</td></tr>'}
 for(const e of data.entries){const full=(cur?cur+"/":"")+e.name;const tr=document.createElement("tr");
  const link=e.dir?'<a href="#/'+enc(full)+'">'+esc(e.name)+'/</a>':'<a href="/files/'+enc(full)+'" download="'+esc(e.name)+'">'+esc(e.name)+'</a>';
  tr.innerHTML='<td>'+link+'</td><td class="n">'+(e.dir?"":human(e.size))+'</td><td class="n">'+(e.dir?"":when(e.mtime))+'</td>'+
   '<td class="acts"><button data-a="share" title="Link public">Link</button><button data-a="rename" title="Redenumeste">Redenumeste</button><button data-a="del" title="Sterge">Sterge</button></td>';
  tr.querySelectorAll("button").forEach(b=>b.onclick=()=>action(b.dataset.a,full,e));rows.appendChild(tr)}
 try{const me=await (await api("/api/me")).json();$("#who").textContent=" "+me.name+" · "+human(me.used)+(me.quota?" din "+human(me.quota):"")}catch(e){}
}
async function action(a,full,e){
 if(a==="del"){if(!confirm("Stergi "+(e.dir?"directorul cu tot continutul":"fisierul")+" \""+e.name+"\"?"))return;
  try{await api("/files/"+enc(full),{method:"DELETE"});msg("Sters: "+e.name)}catch(x){msg(x.message,true)}load()}
 else if(a==="rename"){const n=prompt("Numele nou:",e.name);if(!n||n===e.name)return;if(n.includes("/")){msg("Numele nu poate contine /",true);return}
  const to=(cur?cur+"/":"")+n;try{await api("/api/move",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({from:full,to})});msg("Redenumit: "+n)}catch(x){msg(x.message,true)}load()}
 else if(a==="share"){$("#share-what").textContent=full;$("#share-pass").value="";$("#share-days").value="";const d=$("#dlg-share");d.showModal();
  d.onclose=async()=>{if(d.returnValue!=="ok")return;const body={path:full};const p=$("#share-pass").value;const z=$("#share-days").value;
   if(p)body.password=p;if(z)body.days=Number(z);
   try{const s=await (await api("/api/shares",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)})).json();
    try{await navigator.clipboard.writeText(s.url)}catch(_){}msg("Link creat (copiat): "+s.url)}catch(x){msg(x.message,true)}}}
}
async function upload(files){if(!files.length)return;let done=0,fail=0;
 for(const f of files){msg("Incarc "+f.name+" ("+human(f.size)+")... "+(done+fail+1)+"/"+files.length);
  try{await api("/files/"+enc((cur?cur+"/":"")+f.name),{method:"PUT",body:f,headers:{"X-OC-Mtime":String(Math.floor(f.lastModified/1000))}});done++}
  catch(x){fail++;msg(f.name+": "+x.message,true);await new Promise(r=>setTimeout(r,1500))}}
 msg(done+" fisiere incarcate"+(fail?", "+fail+" cu eroare":""),fail>0);load()}
$("#btn-upload").onclick=()=>$("#file").click();
$("#file").onchange=e=>{upload([...e.target.files]);e.target.value=""};
$("#btn-folder").onclick=async()=>{const n=prompt("Numele directorului nou:");if(!n)return;if(n.includes("/")){msg("Numele nu poate contine /",true);return}
 try{await api("/api/dirs/"+enc((cur?cur+"/":"")+n),{method:"PUT"});msg("Director creat: "+n)}catch(x){msg(x.message,true)}load()};
$("#btn-shares").onclick=async()=>{const tb=$("#shares tbody");tb.innerHTML='<tr><td class="muted">Se incarca...</td></tr>';$("#dlg-shares").showModal();
 try{const list=await (await api("/api/shares")).json();tb.innerHTML=list.length?"":'<tr><td class="muted">Niciun link.</td></tr>';
  for(const s of list){const tr=document.createElement("tr");
   tr.innerHTML='<td>'+esc(s.path)+'<br><a href="'+esc(s.url)+'" target="_blank" rel="noopener">'+esc(s.url)+'</a><br><span class="small muted">'+(s.password?"cu parola · ":"")+(s.expires?"expira "+when(s.expires)+" · ":"")+s.downloads+' descarcari</span></td><td class="acts"><button>Sterge</button></td>';
   tr.querySelector("button").onclick=async()=>{try{await api("/api/shares/"+s.token,{method:"DELETE"});tr.remove()}catch(x){msg(x.message,true)}};tb.appendChild(tr)}}
 catch(x){tb.innerHTML='<tr><td class="err">'+esc(x.message)+'</td></tr>'}};
$("#shares-close").onclick=()=>$("#dlg-shares").close();
const drop=$("#drop");
["dragenter","dragover"].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.add("over")}));
["dragleave","drop"].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.remove("over")}));
drop.addEventListener("drop",e=>upload([...e.dataTransfer.files]));
window.addEventListener("hashchange",load);load();
</script></body></html>"##
);
