# Playbook public image cache

`https://playbook-images.xmevans10.workers.dev/v1/player-headshots/<key>` and
`/v1/team-logos/<key>` cache the corresponding public Supabase originals. There are no
secrets, private buckets, arbitrary upstream URLs, or image-transformation calls in this Worker.
Photos are already optimized during ingestion; iOS retains local downsampling, decoded caching,
in-flight coalescing, provider resizing, and the original-URL fallback.

The Worker was deployed and verified on 2026-10-04. Samples of 10–20 KB were byte-identical
to their origins, repeat requests returned `X-Playbook-Cache: HIT`, and private buckets and
arbitrary proxy inputs returned 404. Browser cache TTL is one day; edge TTL is one week.
Cache entries are local to each Cloudflare data center and may be evicted sooner. An image
replaced at the same storage key can remain stale for up to a week; changing its key avoids this.

## Cutover status

- Deployed: the Cloudflare Worker.
- Prepared in app source: route Playbook's two public image buckets through this cache. This
  routing reaches users with the next app release; no App Store release was submitted here.
- Prepared in ingestion: retire `headshots --warm-transforms` as a no-op, warm one cached
  original per image, and change the weekly workflow from all-catalog warming to puzzle warming.
- Pending explicit approval: set Supabase project `nhccgufqwndtoasdbkhc`'s storage config
  `features.imageTransformation.enabled` to `false`, then read it back and verify original
  images remain available. Existing app builds already retry the original URL on a non-2xx
  transform response; they incur a failed transform request on cold loads until updated.
- No production database URLs, write triggers, storage objects, or access policies were changed.

Supabase bills distinct origin images each billing cycle, including cached transformations:
https://supabase.com/docs/guides/platform/manage-your-usage/storage-image-transformations
The dashboard showed 529 origins versus 100 included on 2026-10-04. Removing transforms cannot
reverse accrued usage. All-catalog warming would expose 65,414 stored photos to this charge.

Deploy future Worker edits using the adjacent `wrangler.jsonc`, or the Cloudflare module-upload
API with `main_module: worker.mjs` and equivalent observability configuration. Do not add paid
Cloudflare image transformations: these origins are already optimized at ingestion.
