# Local patches to Notelet

None. The vendored source is byte-identical to upstream `0298690`.

Kept as a file rather than a line in VENDORING.md so that the first patch has an obvious
home — an undocumented divergence is what makes a vendored dependency expensive to upgrade.

## Things worth knowing that are NOT patches

- **Media is rendered square** (`NoteItemView` frames it `containerWidth` x `containerWidth`,
  `scaledToFill`). Artwork that isn't square gets cropped on both edges, which is why
  `OPMSlideGalleryTests` authors every poster square.
- **Media loads through `AsyncImage(url:)`**, so slides need a `URL`, not an `Image`. Our art
  therefore ships as loose PNGs in the bundle (`BallIQ/Resources/OPM/`) rather than as an
  asset-catalog imageset; `file://` URLs work because `AsyncImage` goes through `URLSession`.
  Verified on device 2026-08-28.
- **`.current` matches `CFBundleShortVersionString`** (`Helpers.getCurrentAppVersion`), and the
  "already seen" flag is a single `UserDefaults` string under `Notelet.LatestSeenAppVersion` —
  not a per-version set. So the sheet shows once per version, and a downgrade would re-show.
- **`NoteletVersionNoteItem.media` requires a `description`.** We pass `""` on purpose: the
  house rule is one message per slide (see `UpdateNotes`), and filling this in would quietly
  make it two.
