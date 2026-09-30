// Watch Time v3 - service worker doar pentru notificari (nu salveaza pagini in cache).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = {body: e.data ? e.data.text() : ''}; }
  // fmt 0: clasic (titlu, from Watch Time, text)
  // fmt 1: titlu gol -> "from Watch Time" sus, apoi serialul/filmul si textul
  // fmt 2: totul in titlu -> serialul/filmul si textul sus, "from Watch Time" jos
  const fmt = d.fmt ?? (d.compact ? 1 : 0), both = [d.title, d.body].filter(Boolean).join('\n');
  const title = fmt === 2 ? both : fmt === 1 ? '' : (d.title || 'Watch Time');
  const body = fmt === 2 ? '' : fmt === 1 ? both : (d.body || '');
  e.waitUntil(self.registration.showNotification(title, {
    body, tag: d.tag || undefined, icon: '/icon-192.png', badge: '/icon-192.png',
    data: {url: d.url || '/'},
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || '/', self.location.origin).href;
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
    for (const c of all) {
      if (new URL(c.url).origin === self.location.origin) { await c.focus(); return c.navigate(url); }
    }
    return self.clients.openWindow(url);
  })());
});
