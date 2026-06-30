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
                        .foregroundStyle(format.isPro ? Color.proText : Color.accentText)
                    Spacer()
                    if format.isPro {
                        Text("Pro")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.proText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.proBg)
                            .clipShape(Capsule())
                    } else if !format.isPlayable {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textMuted)
                    }
                }
                Text(format.name.uppercased())
                    .font(.custom(FontName.condBold, size: 16))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.leading)
                Text((format.isPlayable ? "Daily" : (format.isPro ? "Pro only" : "Soon")).uppercased())
                    .font(.label11)
                    .foregroundStyle(format.isPlayable ? Color.accentText : Color.textMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .cardSurface()
            .opacity(dimmed ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!format.isPlayable)
    }
}
