import SwiftUI

/// The round glass X in the top corner of a full-height sheet.
///
/// The glass comes from `glassEffect` on a plain button, not from the `.glass`
/// button style. On iPad, a `.glass` button laid over a sheet's scroll view
/// draws but never receives taps.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .padding(12)
    }
}
