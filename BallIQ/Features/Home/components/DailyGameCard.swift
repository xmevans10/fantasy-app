import SwiftUI

/// A "today's daily game" card — a broadcast "matchup" block with a colored header band.
struct DailyGameCard: View {
    let formatName: String
    let symbol: String
    let sport: Sport
    let title: String
    let subtitle: String
    /// Optional author's note (community puzzles) — shown as a second line under the subtitle.
    var description: String? = nil
    /// Optional grading-philosophy badge (PPR / era-adjusted / author's call) in the header band.
    var scoring: ScoringKind? = nil
    /// Optional grain badge (Season / Single Game / Career) in the header band. nil for
    /// Who Am I? cards, which have no grain concept.
    var grain: PuzzleGrain? = nil
    let completed: Bool
    /// True when one of this puzzle's cards belongs to the signed-in user's favorite team for
    /// `sport` — surfaces as a "YOUR TEAM" badge. Only Keep4 puzzles carry structured
    /// `teamAbbr` data per card today; Who Am I's clues are free text, so it's always false there.
    var favoriteTeamMatch: Bool = false
    /// Puzzle-type signifier chip color (e.g. blue for K4C4, volt for Who Am I) — the header
    /// band itself is colored by `sport` (see `Sport.cardFill`), not by type.
    var typeColor: Color = .accentFill
    var onTypeColor: Color = .onAccent
    /// Card body fill — community cards pass a warm tint to read "hand-made" vs the daily white.
    var bodyFill: Color = .surface1
    /// True when this session moves the player's competitive rating (the daily K4C4/WhoAmI
    /// cards). Off by default so community/archive cards — XP-only by design — stay unmarked.
    var ranked: Bool = false
    /// Optional freshness stamp ("TODAY · SAT, JUL 19") — only the true daily cards pass
    /// `DailyGameCard.todayDateBadge`, so archive/community cards never falsely claim to be new.
    var dateBadge: String? = nil
    let action: () -> Void
    /// Optional secondary action — an explicit overflow icon in the header band, distinct from
    /// the card's primary tap-to-play. nil (default) hides it; only Community cards pass one
    /// (report puzzle). A nested `Button` here works cleanly since its tap frame (a small icon in
    /// the header) never overlaps the rest of the card's tap area.
    var secondaryAction: (() -> Void)? = nil

    /// "TODAY · SAT, JUL 19" — the device-local calendar date, not the UTC `active_date` key:
    /// the badge answers "is this fresh?" in the user's own calendar, and showing the UTC day
    /// would read as tomorrow's date every US evening.
    static var todayDateBadge: String {
        let day = Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return String(localized: "TODAY · \(day)").uppercased()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Colored header band, two rows so it never breaks regardless of sport or
                // scoring kind: the format name (row 1) is never a compression target, and
                // the badge row (row 2) scrolls instead of truncating. A single-row layout
                // with the badges inline used to starve the format name of width whenever a
                // badge's text ran long (era-adjusted's badge is ~3x PPR's) — it would
                // compress the format name down past legibility into a bare "…". Two fixed
                // rows are the template every sport/kind combination shares, present and
                // future, with no per-case tuning.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: sport.symbol)
                        Text(sport.displayName.uppercased())
                            .font(.heading)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let secondaryAction {
                            Button(action: secondaryAction) {
                                Image(systemName: "ellipsis.circle.fill")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("More options")
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            // Puzzle-TYPE signifier — its own solid-color chip since the header
                            // band itself is now colored by sport, not type.
                            badge(symbol: symbol, text: formatName.uppercased(), fill: typeColor, foreground: onTypeColor)
                            if let dateBadge {
                                badge(symbol: "calendar", text: dateBadge)
                            }
                            if ranked {
                                badge(symbol: "chart.line.uptrend.xyaxis", text: String(localized: "RANKED"))
                            }
                            if let scoring {
                                badge(symbol: scoring.symbol, text: scoring.badgeLabel(for: sport))
                            }
                            if let grain {
                                badge(symbol: grain.symbol, text: grain.badgeLabel)
                            }
                            if favoriteTeamMatch {
                                badge(symbol: "star.fill", text: String(localized: "YOUR TEAM"))
                            }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .foregroundStyle(sport.onCardFill)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sport.cardFill)

                // Body
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title)
                            .foregroundStyle(Color.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle.uppercased())
                            .font(.label11)
                            .foregroundStyle(Color.textMuted)
                        if let description, !description.isEmpty {
                            Text(description)
                                .font(.body14)
                                .foregroundStyle(Color.textMuted)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if completed {
                        // A filled "seal" — reads as finished at a glance, not a faint label.
                        // The whole card also gets a done treatment below (tinted body, muted
                        // header, check overlay) so completion is obvious even in a scanned list.
                        Label("DONE", systemImage: "checkmark.seal.fill")
                            .font(.heading)
                            .foregroundStyle(Color.onSuccess)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Color.successFill)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    } else {
                        Text("PLAY")
                            .font(.heading)
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Color.accentFill)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                // Completed cards get a soft success wash instead of the plain body fill, so a
                // done puzzle is distinguishable from an unplayed one at a scan, not only by the
                // corner control.
                .background(completed ? Color.successBg : bodyFill)
                .accessibilityElement(children: .combine)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            // Mute a completed card's sport color so the vivid header reads as "still to play"
            // and the desaturated one as "done" — the strongest at-a-glance signal in a list.
            .saturation(completed ? 0.55 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(completed ? Color.successFill : Color.borderInk,
                                  lineWidth: completed ? 2.5 : 2)
            )
            .overlay(alignment: .topTrailing) {
                // A small checkmark seal notched into the top-right corner — the universal
                // "checked off" affordance the request asked for, on top of the color changes.
                if completed {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.successFill)
                        .background(Circle().fill(Color.surface).padding(2))
                        .offset(x: 7, y: -7)
                        .accessibilityHidden(true)
                }
            }
            // Slightly de-emphasized overall — done, but still tappable to review/replay.
            .opacity(completed ? 0.92 : 1)
            .shadow(color: Color.black.opacity(0.14), radius: 0, x: 0, y: 4)
        }
        .buttonStyle(PrimePressStyle())
        .accessibilityLabel(completed ? "\(formatName), \(title). Completed." : "\(formatName), \(title)")
    }

    /// One header-band badge (type / scoring / grain) — same capsule for all three instead
    /// of a copy-pasted literal per badge, so a fourth kind (if one's ever added) is a
    /// one-line call, not a fourth near-identical block. `fill`/`foreground` default to a
    /// translucent tint of the header ink; the type badge overrides both with a solid color
    /// since it's the puzzle-type signifier and needs to read at a glance, not blend in.
    private func badge(symbol: String?, text: String, fill: Color? = nil, foreground: Color? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.label11).lineLimit(1)
        }
        .fixedSize()   // never wrap mid-capsule — the scroll view absorbs overflow instead
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(foreground ?? sport.onCardFill)
        .background(fill ?? sport.onCardFill.opacity(0.18))
        .clipShape(Capsule())
    }
}
