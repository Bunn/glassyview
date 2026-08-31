import SwiftUI

/// Dedicated display picker for real multi-screen metadata or combined
/// framebuffers that can be split into likely display regions.
struct SessionDisplayMenu<Session: RemoteSessionControlling>: View {
    @ObservedObject var session: Session

    var body: some View {
        Menu {
            Picker("Display", selection: displayBinding) {
                ForEach(session.displayOptions) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option.selection)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Display", systemImage: "rectangle.split.2x1")
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityHint("Chooses which remote display to show.")
    }

    private var displayBinding: Binding<RemoteDisplaySelection> {
        Binding {
            session.displaySelection
        } set: { selection in
            session.setDisplaySelection(selection)
        }
    }
}
