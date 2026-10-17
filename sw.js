const C='saude-v7',A=['./','index.html','manifest.webmanifest','icon-192.png','icon-512.png','apple-touch-icon.png','favicon-32.png','media/mascote.jpg'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(C).then(c=>c.addAll(A)));self.skipWaiting()});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim()))});
// network-first sem cache HTTP; guarda cópia para offline
const netFirst=(r,key)=>fetch(r,{cache:'no-store'}).then(res=>{if(res.ok){const cp=res.clone();caches.open(C).then(c=>c.put(key,cp))}return res}).catch(()=>caches.match(key,{ignoreSearch:true}));
self.addEventListener('fetch',e=>{const r=e.request;if(r.method!=='GET')return;const u=new URL(r.url);
 if(u.origin===location.origin&&u.pathname.endsWith('/data/db.json')){e.respondWith(netFirst(r,new URL('data/db.json',self.registration.scope).href));return}
 if(r.mode==='navigate'||u.pathname.endsWith('/')||u.pathname.endsWith('index.html')){e.respondWith(netFirst(r,r).then(m=>m||caches.match('index.html')));return}
 if(u.host.endsWith('supabase.co'))return;
 e.respondWith(caches.match(r).then(m=>m||fetch(r).then(res=>{if(res.ok&&(u.origin===location.origin||u.host==='cdn.jsdelivr.net')){const cp=res.clone();caches.open(C).then(c=>c.put(r,cp))}return res})))});
