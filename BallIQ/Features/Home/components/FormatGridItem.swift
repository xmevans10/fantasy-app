import SwiftUI

struct FormatGridItem: View {
    let format: GameFormat
    let action: () -> Void

    private var dimmed: Bool { format.isPro || !format.isPlayable }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: format.symbol)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(format.onTint)
                    Spacer()
                    if format.isPro {
                        // Paper capsule so the Pro marker still reads on the purple block.
                        Text("Pro")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.proFill)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white)
                            .clipShape(Capsule())
                    } else if !format.isPlayable {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(format.onTint.opacity(0.7))
                    }
                }
                Text(format.name.uppercased())
                    .font(.custom(FontName.condBold, size: 16))
                    .foregroundStyle(format.onTint)
                    .multilineTextAlignment(.leading)
                // "Daily · Ranked" (not just "Daily"): every subtitle-less playable format —
                // K4C4, Who Am I?, The Grid — moves competitive rating on its first daily
                // run, and that used to be invisible here (user feedback 2026-07-17).
                Text(format.subtitle ?? (format.isPlayable ? "Daily · Ranked" : (format.isPro ? "Pro only" : "Soon")))
                    .textCase(.uppercase)
                    .font(.label11)
                    .foregroundStyle(format.onTint.opacity(format.isPlayable ? 0.85 : 0.6))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            // Each format is its own arcade cartridge — bold color block with the sticker
            // ink outline + hard ledge shadow, not six identical white cards (2026-07-17).
            .blockCard(fill: format.tint, lift: 4)
            .opacity(dimmed ? 0.72 : 1)
        }
        .buttonStyle(PrimePressStyle())
        .disabled(!format.isPlayable)
    }
}
