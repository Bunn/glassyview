import SwiftUI

/// A lightweight, resolution-independent illustration of the two devices.
/// It is decorative; the live, scannable QR is a separate accessible view.
struct HostPairingIllustration: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.blue.opacity(colorScheme == .dark ? 0.12 : 0.08))
            Ellipse()
                .fill(.blue.opacity(0.23)).frame(width: 290, height: 170)
                .blur(radius: 38).offset(x: -120, y: 24)
            Ellipse()
                .fill(.cyan.opacity(0.2)).frame(width: 230, height: 150)
                .blur(radius: 32).offset(x: 150, y: -30)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 11)
                    .fill(.regularMaterial)
                    .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.18), lineWidth: 2) }
                    .frame(width: 155, height: 95)
                    .overlay {
                        Image(systemName: "macwindow").font(.system(size: 34, weight: .ultraLight))
                            .foregroundStyle(.blue.opacity(0.75))
                    }
                    .padding(.bottom, 6)
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 181, height: 5)
            }
            .offset(x: -26, y: 7)
            RoundedRectangle(cornerRadius: 15)
                .fill(.regularMaterial)
                .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.5), lineWidth: 3) }
                .frame(width: 63, height: 112)
                .overlay(alignment: .top) {
                    Capsule().fill(.primary.opacity(0.7)).frame(width: 21, height: 5).padding(.top, 7)
                }
                .overlay {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 26, weight: .light))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(.blue)
                }
                .rotationEffect(.degrees(8))
                .offset(x: 69, y: 14)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
