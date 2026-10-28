import SwiftUI

struct DismissibleBanner: View {
    let message: String
    let systemImage: String
    let tint: Color
    let accessibilityPrefix: String
    let dismissLabel: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(message, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityLabel("\(accessibilityPrefix): \(message)")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .accessibilityLabel(dismissLabel)
            .help(dismissLabel)
        }
        .font(.callout)
        // Applied to the HStack so the dismiss glyph picks up the banner tint instead of reading
        // as an unrelated control sitting on the strip.
        .foregroundStyle(tint)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
