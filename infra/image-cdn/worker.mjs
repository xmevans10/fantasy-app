const ORIGIN = 'https://nhccgufqwndtoasdbkhc.supabase.co/storage/v1/object/public';
const BUCKETS = new Set(['player-headshots', 'team-logos']);

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    const parts = url.pathname.split('/');
    if (parts[1] !== 'v1' || !BUCKETS.has(parts[2]) || parts.length < 4 ||
        !/\.(png|jpe?g|webp|gif)$/i.test(url.pathname) ||
        /%2f|%5c|%2e|\\/i.test(url.pathname) ||
        [...url.searchParams.keys()].some(key => key !== 'v') ||
        !/^[a-zA-Z0-9_-]{0,64}$/.test(url.searchParams.get('v') || '') ||
        url.searchParams.getAll('v').length > 1) {
      return new Response('Not found', { status: 404 });
    }
    const key = new Request(url.toString(), { method: 'GET' });
    const cache = caches.default;
    let hit;
    try { hit = await cache.match(key); } catch { /* Origin still works if cache is unavailable. */ }
    if (hit) {
      const headers = new Headers(hit.headers);
      headers.set('X-Playbook-Cache', 'HIT');
      return new Response(request.method === 'HEAD' ? null : hit.body, { headers });
    }
    try {
      // Fixed public origin, no caller credentials or redirects, and no paid transform API.
      const upstream = await fetch(ORIGIN + url.pathname.slice(3), {
        redirect: 'manual', signal: AbortSignal.timeout(15000),
      });
      if (upstream.status !== 200 || !/^image\/(png|jpeg|webp|gif)(;|$)/i.test(upstream.headers.get('Content-Type') || '')) {
        return new Response('Image unavailable', { status: upstream.status === 404 ? 404 : 502 });
      }
      const headers = new Headers({
        'Content-Type': upstream.headers.get('Content-Type'),
        'Cache-Control': 'public, max-age=86400, s-maxage=604800',
        'X-Content-Type-Options': 'nosniff',
      });
      for (const name of ['Content-Length', 'ETag', 'Last-Modified']) {
        if (upstream.headers.has(name)) headers.set(name, upstream.headers.get(name));
      }
      const response = new Response(upstream.body, { headers });
      ctx.waitUntil(cache.put(key, response.clone()).catch(() => {
        console.error(JSON.stringify({ event: 'image_cache_write_failed' }));
      }));
      const clientHeaders = new Headers(headers);
      clientHeaders.set('X-Playbook-Cache', 'MISS');
      return new Response(request.method === 'HEAD' ? null : response.body, { headers: clientHeaders });
    } catch {
      console.error(JSON.stringify({ event: 'image_origin_failed' }));
      return new Response('Image unavailable', { status: 502 });
    }
  },
};
