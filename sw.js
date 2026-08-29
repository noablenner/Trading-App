const CACHE='tt-v15';
const ASSETS=['./','./index.html','./supabase.js','./tuto-ios-1.png','./tuto-ios-2.png','./tuto-app-icon.png','./icon-192.png','./icon-512.png','./favicon.ico','./favicon-32.png','./manifest.webmanifest'];

// Installation : on pré-charge la coquille de l'app (pour le hors-ligne).
// Pas de skipWaiting() automatique ici : le nouveau SW reste "en attente" tant
// que l'utilisateur n'a pas cliqué "Recharger" sur le bandeau de mise à jour
// (voir index.html), pour ne jamais changer de version sous ses pieds.
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS)));});

// Le front demande explicitement l'activation de la nouvelle version.
self.addEventListener('message',e=>{ if(e.data && e.data.type==='SKIP_WAITING') self.skipWaiting(); });

// Activation : on supprime les anciens caches et on prend la main tout de suite
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});

self.addEventListener('fetch',e=>{
  const req=e.request;
  const url=new URL(req.url);
  if(req.method!=='GET') return;              // on ne touche qu'aux lectures
  if(url.origin!==location.origin) return;    // appels Supabase -> réseau direct

  const isHTML = req.mode==='navigate' || (req.headers.get('accept')||'').includes('text/html');

  if(isHTML){
    // Pages HTML -> RÉSEAU D'ABORD : toujours la version fraîche, cache seulement si hors-ligne
    e.respondWith(
      fetch(req).then(res=>{
        const copy=res.clone();
        caches.open(CACHE).then(c=>c.put(req,copy));
        return res;
      }).catch(()=>caches.match(req).then(r=>r||caches.match('./index.html')))
    );
    return;
  }

  // Autres fichiers -> STALE-WHILE-REVALIDATE : cache immédiat + mise à jour en arrière-plan
  e.respondWith(
    caches.match(req).then(cached=>{
      const network=fetch(req).then(res=>{
        if(res && res.status===200){
          const copy=res.clone();
          caches.open(CACHE).then(c=>c.put(req,copy));
        }
        return res;
      }).catch(()=>cached);
      return cached||network;
    })
  );
});
