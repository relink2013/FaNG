/// The admin page: one self-contained HTML file (no external scripts, fonts or styles), served at /admin.
enum AdminPage {
    /// The page with the glyph filled in.
    static let page = html.replacingOccurrences(of: "{{GLYPH}}", with:
        "<svg class=\"glyph\" viewBox=\"0 0 \(AdminAssets.glyphWidth) 100\" aria-hidden=\"true\"><path fill=\"currentColor\" fill-rule=\"evenodd\" d=\"\(AdminAssets.glyphPath)\"/></svg>")
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FaNG Admin</title>
<link rel="icon" type="image/png" href="/admin/icon.png">
<link rel="apple-touch-icon" href="/admin/icon.png">
<style>
:root{--bg:#f5f5f7;--panel:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e3e3e8;--accent:#0a7cff;--accent-soft:#e6f1ff;--danger:#d70015;--ok:#1e9e4a;--warn:#c27c00;--bar:#e9e9ee}
@media (prefers-color-scheme:dark){:root{--bg:#111113;--panel:#1c1c1f;--text:#f5f5f7;--muted:#9a9aa1;--line:#2c2c31;--accent:#3a95ff;--accent-soft:#16263d;--danger:#ff453a;--ok:#32d74b;--warn:#ffb340;--bar:#2a2a30}}
*{box-sizing:border-box}
body{margin:0;font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--text)}
header{display:flex;align-items:center;gap:16px;padding:12px 20px;background:var(--panel);border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
header h1{font-size:17px;margin:0;font-weight:650;letter-spacing:-.01em;display:flex;align-items:center;gap:8px}
.glyph{height:20px;width:auto;color:var(--text)}
#login .logo{width:64px;height:64px;border-radius:14px;display:block;margin:0 0 10px}
nav{display:flex;gap:4px;flex:1;flex-wrap:wrap}
nav button{border:0;background:none;color:var(--muted);padding:7px 12px;border-radius:8px;font:inherit;cursor:pointer}
nav button.on{background:var(--accent-soft);color:var(--accent);font-weight:600}
main{max-width:1200px;margin:0 auto;padding:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 12px;font-weight:600}
.stat{display:flex;justify-content:space-between;gap:12px;padding:5px 0;border-bottom:1px solid var(--line)}
.stat:last-child{border-bottom:0}
.stat span:first-child{color:var(--muted)}
.big{font-size:26px;font-weight:650;letter-spacing:-.02em}
.bar{height:8px;background:var(--bar);border-radius:4px;overflow:hidden;margin:6px 0 2px}
.bar i{display:block;height:100%;background:var(--accent);border-radius:4px}
.store{padding:8px 0;border-bottom:1px solid var(--line)}
.store:last-child{border-bottom:0}
.store .top{display:flex;justify-content:space-between;font-weight:600}
.small{font-size:12px;color:var(--muted)}
.warn{color:var(--warn)}.danger{color:var(--danger)}.ok{color:var(--ok)}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:8px 6px;border-bottom:1px solid var(--line);vertical-align:middle}
th{font-size:12px;color:var(--muted);font-weight:600}
button.b,a.b{border:1px solid var(--line);background:var(--panel);color:var(--text);padding:6px 11px;border-radius:8px;font:inherit;cursor:pointer;text-decoration:none;display:inline-block}
button.b:hover{border-color:var(--accent)}
button.primary{background:var(--accent);color:#fff;border-color:var(--accent)}
button.red{color:var(--danger)}
input,select{font:inherit;padding:7px 9px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--text)}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.crumbs{display:flex;flex-wrap:wrap;gap:2px;align-items:center;margin-bottom:12px}
.crumbs button{border:0;background:none;color:var(--accent);cursor:pointer;font:inherit;padding:2px 4px;border-radius:5px}
.crumbs span{color:var(--muted)}
.files{display:grid;grid-template-columns:repeat(auto-fill,minmax(132px,1fr));gap:10px}
.file{background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden;cursor:pointer;display:flex;flex-direction:column}
.file:hover,.file.sel{border-color:var(--accent)}
.thumb{height:104px;display:flex;align-items:center;justify-content:center;background:var(--bar);font-size:38px;overflow:hidden}
.thumb img{width:100%;height:100%;object-fit:cover}
.fname{padding:6px 8px;font-size:12px;word-break:break-word;line-height:1.3}
.fmeta{padding:0 8px 7px;font-size:11px;color:var(--muted)}
.split{display:grid;grid-template-columns:1fr 320px;gap:16px;align-items:start}
@media (max-width:900px){.split{grid-template-columns:1fr}}
.banner{padding:10px 12px;border-radius:10px;background:var(--accent-soft);margin-bottom:12px}
.pill{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;background:var(--bar)}
.pill.write{background:var(--accent-soft);color:var(--accent)}.pill.none{color:var(--danger)}.pill.through{color:var(--muted)}
#login{max-width:340px;margin:12vh auto}
#login input{width:100%;margin-bottom:10px}
.hidden{display:none!important}
#toast{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:var(--text);color:var(--bg);padding:9px 14px;border-radius:10px;font-size:13px;opacity:0;transition:opacity .2s;pointer-events:none}
#toast.show{opacity:1}
/* While a request is out: a moving bar and "Working…", and the buttons that change things wait for it (so a
   slow save can't be sent again and again). */
#busy{position:fixed;top:0;left:0;right:0;height:3px;overflow:hidden;z-index:20;display:none}
#busy i{position:absolute;top:0;bottom:0;width:30%;background:var(--accent);animation:busy 1.1s ease-in-out infinite}
@keyframes busy{from{left:-30%}to{left:100%}}
body.busy #busy{display:block}
#working{display:none}body.busy #working{display:inline}
body.busy button.primary,body.busy button.red{pointer-events:none;opacity:.55}
</style>
</head>
<body>
<div id="login" class="card hidden">
  <img class="logo" src="/admin/icon.png" alt=""><h1 style="margin:0 0 4px;font-size:20px">FaNG</h1>
  <p class="small" style="margin:0 0 16px">Sign in with your FaNG name and password. Only admins can use this page.</p>
  <form id="loginForm"><input id="lu" autocomplete="username" placeholder="Name" required><input id="lp" type="password" autocomplete="current-password" placeholder="Password" required><button class="b primary" style="width:100%">Sign In</button><p id="lerr" class="small danger"></p></form>
</div>
<div id="app" class="hidden">
<header><h1>{{GLYPH}}FaNG</h1><nav id="nav"></nav><span id="working" class="small">Working…</span><span id="who" class="small"></span><button class="b" id="logout">Sign Out</button></header>
<main id="view"></main>
</div>
<div id="toast"></div><div id="busy"><i></i></div>
<script>
"use strict";
const $=s=>document.querySelector(s);
function el(tag,attrs={},...kids){const e=document.createElement(tag);for(const[k,v]of Object.entries(attrs)){if(k==="class")e.className=v;else if(k.startsWith("on"))e.addEventListener(k.slice(2),v);else if(v!==false&&v!=null)e.setAttribute(k,v===true?"":v)}for(const k of kids.flat()){if(k==null)continue;e.append(k instanceof Node?k:document.createTextNode(String(k)))}return e}
function append(parent,...kids){for(const k of kids.flat())if(k!=null)parent.append(k)}
function toast(t){const e=$("#toast");e.textContent=t;e.classList.add("show");clearTimeout(e._t);e._t=setTimeout(()=>e.classList.remove("show"),2600)}
let busyCount=0;
function busy(delta){busyCount=Math.max(0,busyCount+delta);document.body.classList.toggle("busy",busyCount>0)}
async function api(path,opts={}){busy(1);try{return await apiCall(path,opts)}finally{busy(-1)}}
async function apiCall(path,opts){const r=await fetch(path,{credentials:"same-origin",headers:{"Content-Type":"application/json"},...opts});if(r.status===401){showLogin();throw new Error("Signed out")}let body=null;try{body=await r.json()}catch(e){}if(!r.ok)throw new Error((body&&body.error&&body.error.message)||("Error "+r.status));return body}
function bytes(n){if(n==null)return"–";const u=["B","KB","MB","GB","TB","PB"];let i=0;while(n>=1000&&i<u.length-1){n/=1000;i++}return(i?n.toFixed(n<10?2:n<100?1:0):n)+" "+u[i]}
function num(n){return n==null?"–":Number(n).toLocaleString()}
function ago(t){if(!t)return"–";const s=Date.now()/1000-t;if(s<90)return Math.round(s)+" s ago";if(s<5400)return Math.round(s/60)+" min ago";if(s<172800)return Math.round(s/3600)+" h ago";return Math.round(s/86400)+" days ago"}
function dur(s){if(s<120)return Math.round(s)+" s";if(s<7200)return Math.round(s/60)+" min";if(s<172800)return(s/3600).toFixed(1)+" h";return(s/86400).toFixed(1)+" days"}
const pages={overview:"Overview",shares:"Shares",files:"Files",users:"Users"};let page="overview";
function showLogin(){$("#app").classList.add("hidden");$("#login").classList.remove("hidden")}
$("#loginForm").addEventListener("submit",async e=>{e.preventDefault();$("#lerr").textContent="";try{const r=await fetch("/admin/login",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json"},body:JSON.stringify({user:$("#lu").value,password:$("#lp").value})});const b=await r.json().catch(()=>null);if(!r.ok)throw new Error((b&&b.error&&b.error.message)||"Sign-in failed");$("#lp").value="";start()}catch(err){$("#lerr").textContent=err.message}});
$("#logout").addEventListener("click",async()=>{await fetch("/admin/logout",{method:"POST",credentials:"same-origin"});showLogin()});
async function start(){try{const me=await api("/admin/api/me");$("#who").textContent=me.user;$("#login").classList.add("hidden");$("#app").classList.remove("hidden");go(location.hash.slice(1)||"overview")}catch(e){showLogin()}}
// Opens a page. Setting the hash alone fires hashchange, which calls go(); calling go() as well drew the page
// twice, and the first drawing used up what the second needed (a folder picked in Files to share).
function nav(p){if(location.hash.slice(1)===p)go(p);else location.hash=p}
function go(p){page=pages[p.split("/")[0]]?p.split("/")[0]:"overview";const bar=$("#nav");bar.replaceChildren(...Object.entries(pages).map(([k,v])=>el("button",{class:k===page?"on":"",onclick:()=>nav(k)},v)));render()}
// Each drawing goes into a box of its own, shown only if no newer drawing started meanwhile.
let renderSeq=0;
async function render(){const seq=++renderSeq,v=$("#view"),box=el("div");if(!v.firstChild)v.append(el("p",{class:"small"},"Loading…"));try{await({overview,files,users,shares})[page](box)}catch(e){box.replaceChildren(el("p",{class:"danger"},e.message))}if(seq===renderSeq)v.replaceChildren(box)}
// An error that stays until dismissed (a toast is easy to miss).
function problem(box,message){box.replaceChildren(message?el("div",{class:"banner",style:"background:var(--bar);color:var(--danger)"},message,"  ",el("button",{class:"b",onclick:()=>box.replaceChildren()},"OK")):"")}

// ---------- Overview ----------
async function overview(v){
  const o=await api("/admin/api/overview"),s=o.storage,sys=o.system||{},c=o.counts||{};
  const adr=await api("/admin/api/settings/address").catch(()=>null);
  const parts=[["Trash",s.trash.bytes,`${num(s.trash.items)} items · emptied after ${s.trashDays} days`+(c.oldestTrash?` · oldest ${ago(c.oldestTrash)}`:"")],
    ["Versions",s.versions.bytes,`${num(s.versions.items)} versions · thinned, kept up to ${s.versionDays||"∞"} days`+(c.oldestVersion?` · oldest ${ago(c.oldestVersion)}`:"")],
    ["Thumbnails",s.thumbnails.bytes,`${num(s.thumbnails.items)} files · ${num(c.sharedThumbnails)} shared by contents · removed with their files`],
    ["Database",s.databaseBytes,`${num(s.deletedRecords)} records of deleted items, kept ${s.deletedRecordDays} days`],
    ["Upload temp files",(sys.lastScan||{}).uploadBytes,`${num((sys.lastScan||{}).uploadTemps)} uploads under way or interrupted · removed after 7 days untouched`]];
  const max=Math.max(1,...parts.map(p=>p[1]||0));
  const health=[["Media without a thumbnail yet",c.mediaWithoutThumbnail,c.mediaWithoutThumbnail>0?"warn":"ok"],["Thumbnails that failed",c.thumbnailsFailed,""],["Copies running",c.copyJobs,""],["Copies that failed",c.failedCopies,c.failedCopies>0?"danger":"ok"],["Open conflicts",c.openConflicts,c.openConflicts>0?"warn":"ok"],["Permission rules",c.accessRules,""]];
  const scan=sys.lastScan||{};
  v.replaceChildren(el("div",{class:"grid"},
    el("div",{class:"card"},el("h2",{},"Server"),
      stat("Running for",sys.uptime!=null?dur(sys.uptime):"–"),stat("CPUs",sys.cpus),stat("Load",(sys.load||[]).join(" · ")),
      stat("Memory (fang container)",`${bytes(sys.memoryUsed)} of ${bytes(sys.memoryLimit)}`),stat("Filesystems watched",sys.filesystems),
      stat("Last full scan",scan.at?`${ago(scan.at)} · ${num(scan.entries)} entries in ${(scan.seconds||0).toFixed(1)} s`:"–"),
      stat("Workers",sys.workers?`scan ${sys.workers.scan} · copy ${sys.workers.copy}`:"–"),stat("Shares",o.shares.filter(x=>!x.name.startsWith("~")).map(x=>x.name).join(", ")+(o.shares.some(x=>x.name.startsWith("~"))?` · ${o.shares.filter(x=>x.name.startsWith("~")).length} home folders`:"")||"none")),
    el("div",{class:"card"},el("h2",{},"FaNG's own storage"),...parts.map(([n,b,t])=>el("div",{class:"store"},el("div",{class:"top"},el("span",{},n),el("span",{},bytes(b))),el("div",{class:"bar"},el("i",{style:`width:${Math.max(1,100*(b||0)/max)}%`})),el("div",{class:"small"},t))),
      el("p",{class:"small"},"Everything here is cleaned up on its own by the rules shown. None of it is your files.")),
    el("div",{class:"card"},el("h2",{},"Items"),el("div",{class:"big"},num(c.items)),el("div",{class:"small"},`files and folders (${num(c.folders)} folders)`),
      ...health.map(([n,val,cls])=>stat(n,el("span",{class:cls},num(val))))),
    el("div",{class:"card"},el("h2",{},"Database tables"),...(c.tables||[]).map(t=>stat(t.name,bytes(t.bytes))),stat("Latest change",num(c.latestChange)),stat("Oldest change a device may sync from",c.prunedBelow?num(c.prunedBelow):"any")),
    (o.removedShares||[]).length?el("div",{class:"card"},el("h2",{},"Removed shares"),el("p",{class:"small"},"Records of shares no longer served (items, versions, permissions, thumbnails). They're removed on their own on the date shown; adding the share again keeps them. Files on disk are never touched."),
      ...o.removedShares.map(r=>el("div",{class:"store"},el("div",{class:"top"},el("span",{},r.name),el("button",{class:"b red",onclick:async()=>{if(!confirm(`Remove FaNG's records of "${r.name}" now? Its versions and trash can no longer be reached through FaNG (the folders stay on disk), and adding the share again starts it fresh.`))return;try{await api("/admin/api/removed-shares/"+encodeURIComponent(r.name)+"/purge",{method:"POST"});toast("Cleaned up");render()}catch(e){toast(e.message)}}},"Clean Up Now")),
        el("div",{class:"small"},`${num(r.items)} records · ${num(r.versions)} versions · removed ${ago(r.since)} · cleaned up ${new Date(r.until*1000).toLocaleDateString()}`)))):null,
    adr?addressCard(adr):null,
    el("div",{class:"card"},el("h2",{},"Connected SMB sessions"),(sys.sessions||[]).length?el("table",{},el("tr",{},el("th",{},"User"),el("th",{},"From"),el("th",{},"Encryption")),...sys.sessions.map(x=>el("tr",{},el("td",{},x.user),el("td",{},x.machine),el("td",{},x.encryption||"none")))):el("p",{class:"small"},"None right now."))));
}
// The server's name: optional, and nothing stops working while it's empty or not set up yet.
function addressCard(a){
  const u=el("input",{value:a.url||"",placeholder:"https://files.example.com",style:"width:100%"}),m=el("input",{value:a.smb||"",placeholder:"Leave empty to keep the address devices already use",style:"width:100%"}),x=el("input",{value:(a.proxies||[]).join(", "),placeholder:"None",style:"width:100%"}),err=el("div",{});
  const save=el("button",{class:"b",onclick:async()=>{problem(err,"");try{const r=await api("/admin/api/settings/address",{method:"PUT",body:JSON.stringify({url:u.value,smb:m.value,proxies:x.value.split(",").map(t=>t.trim()).filter(Boolean)})});u.value=r.url;m.value=r.smb;x.value=(r.proxies||[]).join(", ");toast("Saved")}catch(e){problem(err,e.message)}}},"Save");
  return el("div",{class:"card"},el("h2",{},"Server address"),
    el("p",{class:"small"},"Optional. The name this server is reached by, for links, sign-in pages and the app. Devices keep working by the address they already use, whether or not this is set."),
    el("div",{class:"small",style:"margin-top:8px"},"Public address"),u,
    el("div",{class:"small",style:"margin-top:8px"},"SMB address, if it differs from the name above (behind a reverse proxy, the name leads to the proxy and SMB has to reach FaNG itself)"),m,
    el("div",{class:"small",style:"margin-top:8px"},"Reverse proxies in front of FaNG (their addresses, separated by commas)"),x,
    el("p",{class:"small",style:"margin-top:8px"},a.certificate?"A certificate for the public name is in place.":"No certificate for the public name is in place. Use a reverse proxy that has one, or put cert.pem and key.pem in FaNG's config folder under tls/public. Until then FaNG answers with its own certificate, which the app trusts and browsers warn about."),
    err,el("div",{style:"margin-top:8px"},save));
}
function stat(k,v){return el("div",{class:"stat"},el("span",{},k),el("span",{},v instanceof Node?v:(v==null?"–":String(v))))}

// ---------- Files ----------
let filesPath="",selected=null,usersCache=null,groupsCache=null;
async function files(v){
  const b=await api("/admin/api/browse?path="+encodeURIComponent(filesPath));filesPath=b.path;
  if(!usersCache)usersCache=(await api("/admin/api/users")).map(u=>u.name);
  if(!groupsCache)groupsCache=(await api("/admin/api/groups").catch(()=>[])).map(g=>g.name);
  const rel=b.path===b.root?[]:b.path.slice(b.root.length+1).split("/");
  const crumbs=el("div",{class:"crumbs"},el("button",{onclick:()=>{filesPath=b.root;selected=null;render()}},b.root),...rel.map((p,i)=>[el("span",{},"/"),el("button",{onclick:()=>{filesPath=b.root+"/"+rel.slice(0,i+1).join("/");selected=null;render()}},p)]));
  const grid=fileGrid(b.entries,selected,name=>{filesPath=b.path+"/"+name;selected=null;render()},name=>{selected=name;render()},!!b.share);
  const side=el("div",{});
  if(b.share){const target=selected?(b.sharePath?b.sharePath+"/":"")+selected:b.sharePath;const label=selected||(b.sharePath?b.sharePath.split("/").pop():b.share);
    const p=selected?await api(`/admin/api/acl?share=${encodeURIComponent(b.share)}&path=${encodeURIComponent(target)}`):b.permissions;
    side.append(permissionsCard(b.share,target,label,p,!!selected),el("p",{class:"small"},"Easier in Shares, which shows only what's shared, as users see it."))}
  else if(b.containsShare){side.append(el("div",{class:"card"},el("h2",{},"Not shared"),el("p",{class:"small"},`FaNG shares the folder "${b.containsShare}" below this one. Open it to set permissions.`)))}
  else{side.append(el("div",{class:"card"},el("h2",{},"Not shared"),el("p",{class:"small"},"FaNG doesn't serve this folder. Make it a share to use it from the app and over SMB, and to set permissions."),el("button",{class:"b",onclick:()=>{shareDraft={name:b.path.split("/").pop(),path:b.path};nav("shares")}},"Share This Folder…")),
    el("div",{class:"card",style:"margin-top:16px"},el("h2",{},"Home folders"),el("p",{class:"small"},"Or use this folder for home folders: each user gets the folder in here named like them as their own \"Home\" (made if missing)."),el("button",{class:"b",onclick:()=>{homesDraft=b.path;nav("users")}},"Use This Folder for Home Folders…")))}
  v.replaceChildren(crumbs,el("div",{class:"split"},el("div",{},b.total>b.entries.length?el("p",{class:"small"},`Showing ${num(b.entries.length)} of ${num(b.total)}.`):null,b.entries.length?grid:el("p",{class:"small"},"Empty folder.")),side));
}
// Folders and files with thumbnails. Clicking a folder opens it; clicking a file (or right-clicking a folder, where
// permissions can be set) selects it for the panel beside.
function fileGrid(entries,sel,openDir,select,canSelectFolders){
  return el("div",{class:"files"},...entries.map(e=>{const icon=e.dir?"📁":fileIcon(e.name);const t=el("div",{class:"thumb"},e.thumb?el("img",{src:"/admin/api/thumb/"+e.id,loading:"lazy",alt:""}):icon);
    const f=el("div",{class:"file"+(sel===e.name?" sel":""),title:e.dir&&canSelectFolders?e.name+" (right-click for its permissions)":e.name,onclick:()=>{if(e.dir)openDir(e.name);else select(e.name)}},t,el("div",{class:"fname"},e.name),el("div",{class:"fmeta"},e.dir?"Folder":bytes(e.size)));
    if(e.dir&&canSelectFolders){f.addEventListener("contextmenu",ev=>{ev.preventDefault();select(e.name)})}return f}))}
function fileIcon(n){const x=(n.split(".").pop()||"").toLowerCase();if(["jpg","jpeg","png","heic","heif","dng","cr3","cr2","nef","arw","raf","orf","rw2","tif","tiff","webp","gif","psd"].includes(x))return"🖼️";if(["mov","mp4","m4v","mkv","mxf","avi"].includes(x))return"🎞️";if(["mp3","wav","aiff","flac","m4a"].includes(x))return"🎵";if(["pdf"].includes(x))return"📕";if(["zip","7z","rar","tar","gz"].includes(x))return"🗜️";return"📄"}
function permissionsCard(share,path,label,p,isItem){
  const levels={none:"No access",read:"Read only",write:"Read & write"};
  const card=el("div",{class:"card"},el("h2",{},"Permissions"),el("p",{style:"margin:0 0 4px;font-weight:600"},label),el("p",{class:"small",style:"margin:0 0 10px"},`${shareTitle(share)}/${path}`),
    el("p",{class:"small banner"},"Nobody has access unless a rule gives it. A rule applies to everything below it; the closest rule wins. Folders on the way to something a user may open show to them read only, with only that path inside; a share they have nothing in is hidden from them."),
    el("table",{},el("tr",{},el("th",{},"User"),el("th",{},"Can")),...p.effective.map(x=>el("tr",{},el("td",{},x.user),el("td",{},x.through?el("span",{class:"pill through",title:"Shown read only because something inside is open to them; nothing else here is visible to them."},"Passes through"):el("span",{class:"pill "+x.access},levels[x.access]))))));
  const rules=Object.fromEntries((p.rules||[]).map(r=>[r.principal,r.access]));
  const homeRules=(p.rules||[]).filter(r=>r.home).map(r=>r.principal.slice(5));
  const who=el("select",{},el("option",{value:"everyone"},"Everyone"),...(groupsCache||[]).map(g=>el("option",{value:"group:"+g},"Group: "+g)),...usersCache.map(u=>el("option",{value:"user:"+u},u)));
  const what=el("select",{},el("option",{value:""},"Inherit (no rule here)"),...Object.entries(levels).map(([k,t])=>el("option",{value:k},t)));
  const sync=()=>{what.value=rules[who.value]||""};who.addEventListener("change",sync);sync();
  append(card,el("h2",{style:"margin-top:16px"},"Rule here"),el("div",{class:"row"},who,what,el("button",{class:"b primary",onclick:async()=>{try{await api("/admin/api/acl",{method:"PUT",body:JSON.stringify({share,path,principal:who.value,access:what.value||null})});toast("Saved. Devices update within seconds.");render()}catch(e){toast(e.message)}}},"Save")),
    Object.keys(rules).length?el("p",{class:"small"},"Set here: "+Object.entries(rules).map(([k,a])=>(k==="everyone"?"Everyone":k.startsWith("group:")?"Group "+k.slice(6):k.slice(5))+" → "+levels[a]).join(", ")):null,
    homeRules.length?el("p",{class:"small"},`Home folder of ${homeRules.join(", ")}: they can always read and write it (a rule of yours here for them takes its place).`):null,
    el("p",{class:"small"},"Enforced over SMB and in the app; nothing on disk changes (owners, modes and ACLs stay as they are)."));
  return card}

// ---------- Groups ----------
// A group gets access in Files like a user does ("Group: name" in a rule); its members then have it.
function groupsCard(groups,users){
  const err=el("div",{}),name=el("input",{placeholder:"group name",required:true,maxlength:"64"});
  const add=el("form",{class:"row",onsubmit:async e=>{e.preventDefault();problem(err,"");try{await api("/admin/api/groups",{method:"POST",body:JSON.stringify({name:name.value})});toast("Group added");render()}catch(x){problem(err,x.message)}}},name,el("button",{class:"b primary"},"Add Group"));
  const rows=groups.map(g=>{const boxes=users.map(u=>{const c=el("input",{type:"checkbox",checked:g.members.includes(u)});c.dataset.user=u;return el("label",{class:"row small",style:"gap:4px"},c,u)});
    const save=async()=>{problem(err,"");try{await api("/admin/api/groups/"+encodeURIComponent(g.name)+"/members",{method:"PUT",body:JSON.stringify({members:boxes.map(b=>b.firstChild).filter(c=>c.checked).map(c=>c.dataset.user)})});toast("Saved. Devices update within seconds.");render()}catch(x){problem(err,x.message)}};
    return el("tr",{},el("td",{},el("b",{},g.name)),el("td",{},el("div",{class:"row"},...boxes)),el("td",{},el("div",{class:"row"},el("button",{class:"b",onclick:save},"Save"),el("button",{class:"b red",onclick:async()=>{if(!confirm(`Remove the group "${g.name}"? Its members lose whatever only this group gave them. No files are touched.`))return;try{await api("/admin/api/groups/"+encodeURIComponent(g.name),{method:"DELETE"});toast("Group removed");render()}catch(x){problem(err,x.message)}}},"Remove"))))});
  return el("div",{class:"card",style:"margin-top:16px"},el("h2",{},"Groups"),
    el("p",{class:"small"},"Give a group access in Files, like a user, and everyone in it has that access. A rule for a user themself counts before their groups' rules; if two of their groups disagree at the same folder, \"No access\" wins."),
    groups.length?el("table",{},el("tr",{},el("th",{},"Group"),el("th",{},"Members"),el("th",{},"")),...rows):el("p",{class:"small"},"No groups yet."),
    err,el("h2",{style:"margin-top:18px"},"Add a group"),add);
}

// ---------- Users ----------
let homesDraft=null;
async function users(v){
  const list=await api("/admin/api/users");usersCache=list.map(u=>u.name);
  const groups=await api("/admin/api/groups");groupsCache=groups.map(g=>g.name);
  const h=await api("/admin/api/homes");if(homesDraft!=null){h.path=homesDraft;homesDraft=null}
  const hp=el("input",{value:h.path||"",placeholder:"Choose a folder in Files, or type its path",style:"flex:1;min-width:260px"}),he=el("input",{type:"checkbox",checked:!!h.enabled});
  const hc=el("input",{value:h.createMask||"0664",style:"width:70px",title:"New files"}),hd=el("input",{value:h.directoryMask||"0775",style:"width:70px",title:"New folders"});
  const hsync=()=>{he.disabled=!hp.value.trim();if(he.disabled)he.checked=false};hp.addEventListener("input",hsync);hsync();
  const herr=el("div",{});
  const homesCard=el("div",{class:"card",style:"margin-top:16px"},el("h2",{},"Home folders"),
    el("p",{class:"small"},"A folder (like /mnt/pool/homes) holding one folder per user, named exactly like the user, as Unraid's path = …/%U. Each user sees their own as a share called \"Home\", with their files directly in it, and never anyone else's. Existing folders are used as they are; folders with no matching user are left alone; a user without one gets one. The folder can't be (or be inside) a share."),
    el("div",{class:"row"},el("label",{class:"row"},he,"Home folders on"),hp,el("button",{class:"b",onclick:()=>{filesPath=hp.value||"";nav("files")}},"Choose in Files…")),
    el("div",{class:"row",style:"margin-top:8px"},el("span",{class:"small"},"New files"),hc,el("span",{class:"small"},"New folders"),hd,
      el("button",{class:"b primary",onclick:async()=>{problem(herr,"");try{await api("/admin/api/homes",{method:"PUT",body:JSON.stringify({enabled:he.checked,path:hp.value.trim(),createMask:hc.value.trim(),directoryMask:hd.value.trim()})});toast("Saved");render()}catch(e){problem(herr,"Not saved: "+e.message)}}},"Save")),
    herr,
    h.problem?el("p",{class:"small danger"},"Not served: "+h.problem):null,
    h.enabled&&!h.problem&&h.needsRestart?el("div",{class:"banner row"},el("span",{},"Saved. FaNG serves the home folders as they're set now after a restart."),el("button",{class:"b primary",onclick:async()=>{if(!confirm("Restart FaNG now? Open transfers resume after the restart."))return;try{await api("/admin/api/apply",{method:"POST"});toast("Restarting…");setTimeout(()=>location.reload(),20000)}catch(e){toast(e.message)}}},"Apply (Restart FaNG)")):null,
    h.enabled&&!h.problem?el("p",{class:"small"},`${Object.keys(h.homes||{}).length} of ${list.length} users have a home folder${h.needsRestart?"":"; each sees it as \"Home\""}.`):(!h.enabled?el("p",{class:"small"},"Off. Choose the folder first, then turn them on."):null));
  const name=el("input",{placeholder:"name",pattern:"[a-z_][a-z0-9_-]*",required:true}),pass=el("input",{type:"password",placeholder:"password (8+)",required:true,minlength:"8"}),adm=el("input",{type:"checkbox"});
  const add=el("form",{class:"row",onsubmit:async e=>{e.preventDefault();try{await api("/admin/api/users",{method:"POST",body:JSON.stringify({name:name.value,password:pass.value,admin:adm.checked})});toast("User added");render()}catch(err){toast(err.message)}}},name,pass,el("label",{class:"row small"},adm,"Admin"),el("button",{class:"b primary"},"Add User"));
  const rows=list.map(u=>{const devs=el("div",{class:"hidden"},...u.devices.map(d=>el("div",{class:"row small",style:"margin:4px 0"},el("span",{},"Device "+d.id.slice(0,12)+" · added "+ago(d.added)),el("button",{class:"b red",onclick:async()=>{if(!confirm("Sign this device out? It will have to sign in again."))return;try{await api("/admin/api/devices/"+d.id,{method:"DELETE"});toast("Device signed out");render()}catch(e){toast(e.message)}}},"Sign Out"))));
    return[el("tr",{},el("td",{},el("b",{},u.name),el("div",{class:"small"},"uid "+u.uid+(h.enabled&&h.homes&&h.homes[u.name]?" · home "+h.homes[u.name]:""))),
      el("td",{},el("label",{class:"row"},el("input",{type:"checkbox",checked:u.admin,onchange:async e=>{try{await api(`/admin/api/users/${encodeURIComponent(u.name)}/admin`,{method:"PUT",body:JSON.stringify({admin:e.target.checked})});toast("Saved")}catch(err){toast(err.message);render()}}}),"Admin")),
      el("td",{},el("button",{class:"b",onclick:()=>devs.classList.toggle("hidden")},`${u.devices.length} device${u.devices.length===1?"":"s"}`),devs),
      el("td",{},el("div",{class:"row"},el("button",{class:"b",onclick:async()=>{const p=prompt(`New password for ${u.name} (8 or more characters):`);if(!p)return;try{await api(`/admin/api/users/${encodeURIComponent(u.name)}/password`,{method:"POST",body:JSON.stringify({password:p})});toast("Password changed")}catch(e){toast(e.message)}}},"Password…"),
        el("button",{class:"b red",onclick:async()=>{if(!confirm(`Remove ${u.name}? Their devices are signed out and their permission rules removed. Their files stay.`))return;try{await api("/admin/api/users/"+encodeURIComponent(u.name),{method:"DELETE"});toast("User removed");render()}catch(e){toast(e.message)}}},"Remove"))))]});
  v.replaceChildren(el("div",{class:"card"},el("h2",{},"Users"),el("p",{class:"small"},"FaNG's users (separate from Unraid's). They sign in to the app and to SMB with these names and passwords. Only admins can open this page. A new user can open nothing but their home folder (when home folders are on) until you give them access in Files."),el("table",{},el("tr",{},el("th",{},"Name"),el("th",{},"Admin"),el("th",{},"Devices"),el("th",{},"")),...rows.flat()),el("h2",{style:"margin-top:18px"},"Add a user"),add),groupsCard(groups,list.map(u=>u.name)),homesCard);
}

// ---------- Shares ----------
// The shares as users see them: each one's folders and files, with permissions beside, and its settings at its top.
let shareDraft=null,shareAt=null,shareSel=null,shareEditor=false;
function shareTitle(name){return name.startsWith("~")?`Home (${name.slice(1)})`:name}
async function shares(v){
  const s=await api("/admin/api/shares");
  if(!usersCache)usersCache=(await api("/admin/api/users")).map(u=>u.name);
  if(!groupsCache)groupsCache=(await api("/admin/api/groups").catch(()=>[])).map(g=>g.name);
  if(shareDraft){shareAt=null;shareEditor=true}
  if(shareAt)return shareFolder(v,s);
  const levels={none:"No access",read:"Read only",write:"Read & write"};
  const served=s.active.slice().sort((a,b)=>(a.name.startsWith("~")-b.name.startsWith("~"))||a.name.localeCompare(b.name));
  const waiting=s.shares.filter(x=>!s.active.some(a=>a.name===x.name));
  const access=await Promise.all(served.map(x=>api(`/admin/api/acl?share=${encodeURIComponent(x.name)}&path=`).catch(()=>null)));
  const cards=served.map((x,i)=>{const p=access[i];const who=p?p.effective.filter(e=>e.access!=="none"):[];
    return el("div",{class:"card",style:"cursor:pointer",onclick:()=>{shareAt={name:x.name,path:x.path,inner:""};shareSel=null;render()}},
      el("div",{style:"display:flex;gap:10px;align-items:center"},el("span",{style:"font-size:30px"},x.name.startsWith("~")?"🏠":"📁"),el("div",{},el("div",{style:"font-weight:650;font-size:16px"},shareTitle(x.name)),el("div",{class:"small"},x.path))),
      el("div",{style:"margin-top:10px"},who.length?who.map(e=>el("span",{class:"pill "+(e.through?"through":e.access),style:"margin:2px 4px 2px 0",title:e.through?"Can open only some folders inside":levels[e.access]},e.user+(e.through?" · some folders":e.access==="read"?" · read only":""))):el("span",{class:"small warn"},"Nobody can open it yet: open it and give access")))});
  const waitingCards=waiting.map(x=>el("div",{class:"card"},el("div",{style:"font-weight:650"},x.name),el("div",{class:"small"},x.path),el("p",{class:"small danger"},"Not served: "+(x.problem||"saved, not in use yet: Apply restarts FaNG with it"))));
  const editor=el("div",{});
  if(shareEditor)await sharesEditor(editor);
  v.replaceChildren();append(v,el("p",{class:"small",style:"margin-top:0"},"Your shares as users see them. Open one to see its folders and files and to set who may open them; a share's own settings are at its top. Home folders are each user's own Home."),
    el("div",{class:"grid"},...cards,...waitingCards),
    served.length||waiting.length?null:el("p",{class:"small"},"No shares yet."),
    el("div",{class:"row",style:"margin:16px 0"},el("button",{class:"b",onclick:()=>{shareEditor=!shareEditor;render()}},shareEditor?"Hide the Share List":"Add or Edit Shares…"),el("span",{class:"small"},"New shares are picked in Files (Share This Folder…) or typed in the list.")),
    editor);
}
async function shareFolder(v,s){
  const at=shareAt,full=at.path+(at.inner?"/"+at.inner:"");
  const b=await api("/admin/api/browse?path="+encodeURIComponent(full));
  const parts=at.inner?at.inner.split("/"):[];
  const crumbs=el("div",{class:"crumbs"},el("button",{onclick:()=>{shareAt=null;shareSel=null;render()}},"Shares"),el("span",{},"›"),
    el("button",{onclick:()=>{shareAt={...at,inner:""};shareSel=null;render()}},shareTitle(at.name)),
    ...parts.map((p,i)=>[el("span",{},"/"),el("button",{onclick:()=>{shareAt={...at,inner:parts.slice(0,i+1).join("/")};shareSel=null;render()}},p)]));
  const grid=fileGrid(b.entries,shareSel,name=>{shareAt={...at,inner:(at.inner?at.inner+"/":"")+name};shareSel=null;render()},name=>{shareSel=name;render()},true);
  const side=el("div",{});
  const target=shareSel?(at.inner?at.inner+"/":"")+shareSel:at.inner;
  const label=shareSel||(at.inner?parts[parts.length-1]:shareTitle(at.name));
  const p=shareSel?await api(`/admin/api/acl?share=${encodeURIComponent(at.name)}&path=${encodeURIComponent(target)}`):(b.permissions||await api(`/admin/api/acl?share=${encodeURIComponent(at.name)}&path=${encodeURIComponent(target)}`));
  side.append(permissionsCard(at.name,target,label,p,!!shareSel));
  if(!at.inner&&!shareSel)side.append(shareSettingsCard(at.name,s));
  v.replaceChildren(crumbs,el("div",{class:"split"},el("div",{},b.total>b.entries.length?el("p",{class:"small"},`Showing ${num(b.entries.length)} of ${num(b.total)}.`):null,b.entries.length?grid:el("p",{class:"small"},"Empty folder."),
    el("p",{class:"small"},"Click a folder to open it; click a file, or right-click a folder, to set permissions on just that item.")),side));
}
// A share's own settings, saved to the shares file (they apply after a restart).
function shareSettingsCard(name,s){
  const card=el("div",{class:"card",style:"margin-top:16px"},el("h2",{},"Share settings"));
  if(name.startsWith("~")){append(card,el("p",{class:"small"},`${name.slice(1)}'s own Home (the home folder settings are in Users). Only ${name.slice(1)} can open it unless you give others access above.`),el("button",{class:"b",onclick:()=>nav("users")},"Home Folder Settings…"));return card}
  const list=s.shares.map(x=>({...x}));const x=list.find(y=>y.name===name);
  if(!x){append(card,el("p",{class:"small"},"Not in the shares file any more (it goes after the next restart)."));return card}
  const cm=el("input",{value:x.createMask,style:"width:70px"}),dm=el("input",{value:x.directoryMask,style:"width:70px"}),ver=el("input",{type:"checkbox",checked:x.versions});
  const err=el("div",{});
  async function save(next,message){problem(err,"");try{await api("/admin/api/shares",{method:"PUT",body:JSON.stringify(next.map(({draft,problem,...y})=>y))});
    if(confirm(message+" Restart FaNG now to apply it? Open transfers resume after the restart.")){await api("/admin/api/apply",{method:"POST"});toast("Restarting…");setTimeout(()=>location.reload(),20000)}else{toast("Saved; it applies at the next restart.");render()}}catch(e){problem(err,"Not saved: "+e.message)}}
  append(card,stat("Folder",x.path),
    el("div",{class:"row",style:"margin:8px 0"},el("span",{class:"small"},"New files"),cm,el("span",{class:"small"},"New folders"),dm),
    el("label",{class:"row small"},ver,"Keep earlier versions when files change"),err,
    el("div",{class:"row",style:"margin-top:10px"},
      el("button",{class:"b primary",onclick:()=>{x.createMask=cm.value.trim();x.directoryMask=dm.value.trim();x.versions=ver.checked;save(list,"Saved.")}},"Save"),
      el("button",{class:"b red",onclick:()=>{if(!confirm(`Stop sharing "${name}"? Its files stay where they are; FaNG's records of it (versions, trash, permissions) are kept 7 days in case you add it back.`))return;shareAt=null;save(list.filter(y=>y.name!==name),"Removed.")}},"Stop Sharing")),
    el("p",{class:"small"},"Masks: the modes new files and folders get (as Unraid's share settings)."));
  return card}
async function sharesEditor(v){
  const s=await api("/admin/api/shares");const list=s.shares.map(x=>({...x}));
  if(shareDraft){if(!list.some(x=>x.path===shareDraft.path))list.push({name:shareDraft.name,path:shareDraft.path,createMask:"0664",directoryMask:"0775",versions:true,draft:true});shareDraft=null}
  drawShares(v,s,list)}
function drawShares(v,s,list){
  const table=el("table",{},el("tr",{},el("th",{},"Name"),el("th",{},"Folder"),el("th",{},"New files"),el("th",{},"New folders"),el("th",{},"Versions"),el("th",{},"")),
    ...list.map((x,i)=>el("tr",{},el("td",{},el("input",{value:x.name,oninput:e=>x.name=e.target.value,style:"width:140px"})),el("td",{},el("input",{value:x.path,oninput:e=>x.path=e.target.value,style:"width:260px"}),x.problem?el("div",{class:"small danger"},"Not served: "+x.problem):null),
      el("td",{},el("input",{value:x.createMask,oninput:e=>x.createMask=e.target.value,style:"width:70px"})),el("td",{},el("input",{value:x.directoryMask,oninput:e=>x.directoryMask=e.target.value,style:"width:70px"})),
      el("td",{},el("input",{type:"checkbox",checked:x.versions,onchange:e=>x.versions=e.target.checked})),el("td",{},el("button",{class:"b red",onclick:()=>{list.splice(i,1);list.dirty=true;draw()}},"Remove")))));
  function draw(){drawShares(v,s,list)}
  const err=el("div",{});
  if(list.some(x=>x.draft))list.dirty=true;
  table.addEventListener("input",()=>{list.dirty=true});table.addEventListener("change",()=>{list.dirty=true});
  v.replaceChildren(el("div",{class:"card"},el("h2",{},"Share list"),
    el("p",{class:"small"},"Folders FaNG serves (to the app and over SMB). Pick them in Files (Share This Folder…) or type the path. Use pool and disk paths, not /mnt/user: Unraid's user shares don't report changes or allow reflinks. Pick a folder inside a pool (like /mnt/pool/Photos), not the pool itself: FaNG can only write inside its shares (the rest of /mnt is mounted read-only), so it never creates top-level folders that would become Unraid user shares."),
    el("p",{class:"small banner"},"Changes are saved to the shares file and take effect when you apply them, which restarts FaNG (about 30 seconds; open SMB connections reconnect). A new share is hidden from everyone until you give access (open it above). A removed share's records (versions, trash, permissions, thumbnails) are kept 7 days in case you add it back, then removed; its files are never touched."),
    table,el("button",{class:"b",style:"margin-top:8px",onclick:()=>{list.push({name:"",path:s.browseRoot+"/",createMask:"0664",directoryMask:"0775",versions:true});list.dirty=true;draw()}},"Add Share"),
    list.dirty?el("p",{class:"small warn"},"Not saved yet: Save, then Apply."):null,err,el("div",{class:"row",style:"margin-top:12px"},
      el("button",{class:"b primary",onclick:async()=>{problem(err,"");try{await api("/admin/api/shares",{method:"PUT",body:JSON.stringify(list.map(({draft,problem,...x})=>x))});toast("Saved. Apply to use them.");render()}catch(e){problem(err,"Not saved: "+e.message)}}},"Save"),
      el("button",{class:"b",onclick:async()=>{if(list.dirty&&!confirm("Some changes here aren't saved yet: Apply uses the saved shares only. Apply anyway?"))return;if(!confirm("Restart FaNG now with the saved shares? Open transfers resume after the restart."))return;try{await api("/admin/api/apply",{method:"POST"});toast("Restarting…");setTimeout(()=>location.reload(),15000)}catch(e){toast(e.message)}}},"Apply (Restart FaNG)")),
    el("p",{class:"small",style:"margin-top:14px"},"Browse root for picking folders: "+s.browseRoot)));
}
window.addEventListener("hashchange",()=>go(location.hash.slice(1)));
start();
</script>
</body>
</html>
"""#
}
