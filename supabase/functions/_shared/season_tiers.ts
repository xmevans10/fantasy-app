// Rating → tier band for the rating-season badge (M5 Phase F). Mirrored exactly from Swift's
// `Tier.forRating` (BallIQ/Models/Tier.swift) — the minted badge label must match what the app
// shows for the same rating, so these cutoffs are locked in lockstep (see season_tiers.test.ts).
export function tierForRating(rating: number): string {
  if (rating >= 1800) return "legend";
  if (rating >= 1600) return "diamond";
  if (rating >= 1400) return "platinum";
  if (rating >= 1200) return "gold";
  if (rating >= 1000) return "silver";
  return "bronze";
}
