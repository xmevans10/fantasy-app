import SwiftUI

/// Onboarding's second screen: the flippable mode deck that used to share the welcome slide,
/// now with the whole screen to itself. Read straight off `GameFormat.all` rather than a copy of
/// it, so a new format (or a renamed one) shows up here for free — the one thing this screen
/// must never do is drift from Home's own grid.
struct OnboardingModesStep: View {
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flippedFormats: Set<String> = []
    @State private var deckPage: String? = GameFormat.all.first?.id
    /// Cleared the moment the first card flips (auto or manual) — the "TAP TO FLIP" stamp is a
    /// one-time affordance hint, not a permanent label.
    @State private var showFlipHint = true

    /// How each format plays, one line the player can read in the second it takes to flip a
    /// card. Checked against the mode's own game view, not invented — see the file comment
    /// next to each entry below for the source.
    private let howItPlays: [String: LocalizedStringKey] = [
        // Keep4GameView.swift / OnboardingView.howToPlayContent's own rule rows.
        "keep4": "Eight real seasons, one at a time. Keep the four that scored the most.",
        // WhoAmIGameView.swift: `revealedCount` unlocks clues one at a time; each guess costs.
        "whoami": "Clues unlock one by one. Name the player in as few as you can.",
        // JourneymanGameView.swift / CareerPathTimeline.swift: "the whole path is shown at
        // once" — wrong guesses cost you, not looks, so the copy leads with the reveal, not a
        // reveal-by-reveal drip.
        "journeyman": "A whole career shown at once, club by club. Name the journeyman before you run out of guesses.",
        // DraftSpinView.swift: spin a (team, year) per lineup slot, then reveal a simulated
        // season once the lineup is full.
        "draft": "Spin a team and year for every slot, build your lineup, then watch the season play out.",
        // OverUnderGameView.swift: guess whether a real stat clears a shown line.
        "overunder": "Higher or lower? Call the stat before it's revealed.",
        // GridGameView.swift: a 3×3 team x decade board, one guess per cell.
        "grid": "Fill a 3×3 where every square is two conditions at once.",
        // VersusView.swift / DuelSession.swift: the same board, raced against a friend.
        "versus": "Same puzzle, a friend, head-to-head.",
        // BlitzGameView.swift: real boards from every format, back to back until the clock stops.
        "blitz": "Race the clock through every format.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Space.lg) {
                    headline
                    deck
                    pageDots
                }
                .padding(.top, Space.sm)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            OnboardingCTA(title: "PICK YOUR SPORT", action: onContinue)
        }
        .onAppear { scheduleAutoFlip() }
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(spacing: 8) {
            Text("8 WAYS TO PROVE IT")
                .font(.hero(34))
                .foregroundStyle(Color.onPro)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(2)
            if showFlipHint {
                PopStamp(text: "TAP TO FLIP", fill: .voltFill, on: .onVolt, angle: -6, size: 14)
            }
        }
        .heroReveal(0)
    }

    // MARK: - Deck

    private var deck: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.md) {
                ForEach(GameFormat.all) { format in
                    modeCard(format)
                        .frame(width: 260, height: 320)
                        .scrollTransition(axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.86)
                                .rotationEffect(.degrees(phase.value * -6))
                                .opacity(phase.isIdentity ? 1 : 0.7)
                        }
                        .id(format.id)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 14)
        }
        // The centred card's ledge shadow and the side cards' tilt draw outside the scroll
        // bounds; clipping them cut the deck's top edge flat.
        .scrollClipDisabled()
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $deckPage)
        .scrollIndicators(.hidden)
        .safeAreaPadding(.horizontal, 55)
        .heroReveal(1)
    }

    private func modeCard(_ format: GameFormat) -> some View {
        let isFlipped = flippedFormats.contains(format.id)
        return ZStack {
            modeFront(format).opacity(isFlipped ? 0 : 1)
            modeBack(format)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
        }
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .contentShape(Rectangle())
        .onTapGesture { flip(format.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: format.name) + Text(", ") + Text(isFlipped ? howItPlays[format.id] ?? "" : tagLabel(format)))
        .accessibilityHint(Text("Double tap to flip"))
    }

    private func flip(_ id: String) {
        Haptics.tap()
        showFlipHint = false
        withAnimation(reduceMotion ? .none : .spring(response: 0.55, dampingFraction: 0.68)) {
            if flippedFormats.contains(id) { flippedFormats.remove(id) } else { flippedFormats.insert(id) }
        }
    }

    /// Flips the first card once, unprompted, ~1s after the deck appears — the affordance for
    /// "these turn over" a brand-new player has no reason to guess at otherwise. Skipped under
    /// Reduce Motion (an unrequested flip is itself a motion effect) and skipped entirely if the
    /// player has already flipped something by hand in that second.
    private func scheduleAutoFlip() {
        guard !reduceMotion, let first = GameFormat.all.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard flippedFormats.isEmpty else { return }
            flip(first.id)
        }
    }

    private func modeFront(_ format: GameFormat) -> some View {
        VStack(spacing: 10) {
            tagChip(format)
            Spacer(minLength: 0)
            modeSticker(format)
            Text(verbatim: format.name)
                .font(.custom(FontName.condBlack, size: 22))
                .foregroundStyle(format.onTint)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("TAP TO FLIP")
                .font(.label11)
                .foregroundStyle(format.onTint.opacity(0.7))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blockCard(fill: format.tint)
    }

    /// Big sticker-circle icon: format-tinted fill, ink ring, hard offset shadow — the same
    /// rhythm as the sport picker's icons, scaled up for the front of a much bigger card.
    private func modeSticker(_ format: GameFormat) -> some View {
        Image(systemName: format.symbol)
            .font(.system(size: 30, weight: .black))
            .foregroundStyle(format.tint)
            .frame(width: 62, height: 62)
            .background(
                ZStack {
                    Circle().fill(Color.borderInk).offset(x: 3, y: 3)
                    Circle().fill(format.onTint)
                    Circle().strokeBorder(Color.borderInk, lineWidth: 2.5)
                }
            )
            .accessibilityHidden(true)
    }

    private func modeBack(_ format: GameFormat) -> some View {
        VStack(spacing: 12) {
            Image(systemName: format.symbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(format.onTint.opacity(0.85))
            Text(howItPlays[format.id] ?? "")
                .font(.bodyStrong)
                .foregroundStyle(format.onTint)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blockCard(fill: format.tint)
    }

    private func tagChip(_ format: GameFormat) -> some View {
        Text(tagLabel(format))
            .font(.custom(FontName.condBlack, size: 11))
            .foregroundStyle(format.onTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(format.onTint.opacity(0.6), lineWidth: 1))
    }

    /// PRO wins outright (`isPro` locks the format regardless of cadence); Versus is the one
    /// social/head-to-head loop; Draft & Spin and Puzzle Blitz are the two formats with no daily
    /// obligation (`GameFormat.arcade`); everything else is a daily. Over/Under is deliberately
    /// *not* tagged Arcade here — `GameFormat.all`'s own comment records that its "Arcade" label
    /// was removed on 2026-07-17 for hiding that first play each day is ranked.
    private func tagLabel(_ format: GameFormat) -> LocalizedStringKey {
        if format.isPro { return "PRO" }
        if format.id == "versus" { return "HEAD-TO-HEAD" }
        if format.id == "draft" || format.id == "blitz" { return "ARCADE" }
        return "DAILY"
    }

    // MARK: - Page dots

    /// Chunky ink-outlined pills, the same vocabulary as `OnboardingProgress` — this deck is a
    /// second, smaller "where am I" inside one slide, so it borrows the outer progress bar's
    /// shape rather than the thin dot row the welcome deck used.
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(GameFormat.all) { format in
                let active = format.id == deckPage
                Capsule()
                    .fill(active ? Color.voltFill : Color.surface1)
                    .overlay(Capsule().strokeBorder(Color.borderInk, lineWidth: 1.5))
                    .frame(width: active ? 22 : 10, height: 8)
            }
        }
        .animation(Motion.overshoot, value: deckPage)
        .accessibilityHidden(true)
    }
}

#Preview {
    OnboardingModesStep(onContinue: {})
}
