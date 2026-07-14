// HisabKitab service-worker removal shim.
// Offline caching is intentionally disabled until authentication and deployment
// paths are stable. Installing this file replaces older workers, deletes their
// caches, releases controlled pages, and unregisters itself.

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(
      keys
        .filter((key) => key.toLowerCase().includes("hisabkitab"))
        .map((key) => caches.delete(key))
    );

    await self.registration.unregister();

    const clients = await self.clients.matchAll({
      type: "window",
      includeUncontrolled: true,
    });

    for (const client of clients) {
      client.navigate(client.url);
    }
  })());
});

// Do not intercept any request while this cleanup worker is active.
self.addEventListener("fetch", () => {});
