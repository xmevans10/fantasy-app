# M5 — Monetization + breadth: Pro (StoreKit), packs, new formats, seasons

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.

## Goal

Make Playbook a business and broaden the content: ship the **Pro subscription** and **format packs**
via StoreKit 2 with proper gating, add the **remaining game formats** (Over/Under, Draft & Spin, and
the Pro-only Grid), and add the **8-week season structure** with cosmetic rewards. After this, the app
has a revenue model and enough format variety to sustain the "multi-format daily" promise.

## Why now

By M4 the core loop, real content, and retention are in place — the right time to monetize (selling
into an engaged base converts far better) and to expand formats so Pro has compelling exclusives.

## Current state to build on

- Freemium gating points already exist conceptually: formats are marked free/Pro and "playable" in
  `GameFormat` (`BallIQ/Features/Home/GameFormat.swift`); the formats grid dims Pro/locked items.
- Repository seam + `RepositoryContainer.complete(...)` handle any format's results; new formats plug
  into the same rating/XP/streak pipeline and the Prime Time design system + juice helpers
  (`heroReveal`, confetti, `CountUpText`, `blockCard`).
- Per-user identity + sync (M2) is the home for entitlement state; seasons build on `ratings`/history.

## Scope

1. **StoreKit 2 monetization:**
   - **Pro** subscription ($4.99/mo, $34.99/yr) and one-time **format packs** ($1.99–$3.99).
   - **Entitlement gating:** The Grid (Pro), all-sport daily access, unlimited Over/Under lives, hard
     mode, archive, no ads. A single `Entitlements` source of truth the UI reads.
   - **Server-side validation:** verify StoreKit transactions / App Store Server Notifications and
     persist entitlement per user (Supabase), so Pro state syncs across devices and can't be spoofed.
2. **Remaining formats** (each plugs into the existing result/rating pipeline + design system):
   - **Over/Under** — swipe Over/Under on a stat threshold; combo multiplier; **lives** (3 free,
     regen 1/hr; unlimited for Pro); arcade session high score.
   - **Draft & Spin** — animated slot-machine constraint → draft a lineup → deterministic season sim →
     shareable record. Haptic/sound on spin + reveal.
   - **The Grid** (Pro) — 3×3 with row/column criteria, rarity scoring, 9 guesses, daily.
3. **Season structure:** 8-week seasons; soft reset to **80%** of end rating; cosmetic end-of-season
   rewards (peak-tier badge, card back, animated border); season countdown on Home/Leagues.

## Key decisions (recommend, then confirm)

- **StoreKit 2** (modern async API), not StoreKit 1. Products configured in **App Store Connect**
  (user-side); a local `.storekit` config enables simulator testing without real purchases.
- **Entitlement source of truth:** validate on-device with StoreKit 2 `Transaction.currentEntitlements`
  for instant UX, **and** persist/verify server-side (App Store Server Notifications v2 → an endpoint
  that writes an `entitlements` row in Supabase) so Pro syncs across devices and survives reinstalls.
  Never trust the client alone for anything that costs money to grant.
- **Sim-testable first:** build against a `Products.storekit` local config so the whole flow
  (paywall → purchase → unlock → gated content) is verifiable in the simulator before real products.
- **Format scope:** if time-boxed, ship **Over/Under** first (simplest, high engagement), then Draft &
  Spin, then The Grid. Each is independently shippable.
- **No ads in this milestone** unless asked — the brief allows results-screen ads, but subscription +
  packs are the priority; ads can be a later add.

## Approach (outline)

1. StoreKit 2 store + `Products.storekit` config + an `Entitlements` model the UI reads; gate The Grid
   / all-sport / hard mode / archive behind it. Paywall screen in Prime Time style.
2. Server-side receipt/notification validation → `entitlements` table (RLS) → synced via `RemoteSync`.
3. Over/Under format (lives + combo) → Draft & Spin (slot + sim) → The Grid (Pro). Reuse the
   result/rating pipeline and juice.
4. Season structure: a `seasons` rollover (Edge Function/cron) doing the 80% soft reset + cosmetic
   reward grants; countdown UI.

## Deliverables

- StoreKit 2 purchase + restore + entitlement gating, server-validated and synced.
- Three new playable formats wired into rating/XP/streak and the design system.
- Season rollover + cosmetic rewards + countdown.
- Paywall + Pro management UI.

## Verification / success criteria

- With a local `.storekit` config in the simulator: buy Pro → The Grid + hard mode + all-sport daily
  unlock immediately; restore purchases works; canceling re-locks. Screenshot the paywall + an
  unlocked Pro feature.
- Server entitlement row is written/verified; a second device/relaunch reflects Pro state.
- Each new format is playable end-to-end and feeds rating/XP/streak correctly (screenshots).
- A simulated season rollover applies the 80% soft reset and grants the cosmetic reward.
- All existing tests green; new pure logic (lives/combo/sim/rarity scoring, soft-reset math) tested.

## Hand-offs (cannot be done by the agent)

- Creating products (Pro subscription + packs) in App Store Connect and the paid-apps agreement.
- App Store Server Notifications endpoint configuration + any signing keys (server-side secrets).
