# Notelet (vendored)

Source: https://github.com/mykolaharmash/notelet @ 0298690
License: MIT (see LICENSE)

Vendored as source rather than added via SPM, for the same reason ConfettiSwiftUI is:
`BallIQ.xcodeproj` is hand-written with Xcode 16+ synchronized file groups
(`objectVersion 77`), so any `.swift` under `BallIQ/` compiles into the app target
automatically and SPM is avoidable. `Package.swift` and the package's `Assets/` are
deliberately not copied — they have no role in this build.

## Local patches
See PATCHES.md. Keep that file current when re-vendoring: the whole cost of vendoring is
paid at upgrade time, and an undocumented patch is how that cost becomes a surprise.
