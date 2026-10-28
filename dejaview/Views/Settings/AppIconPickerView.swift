import SwiftUI

struct AppIconPickerView: View {
    @Environment(SubscriptionStore.self) private var subscriptionStore

    @State private var selection = AppIconOption(alternateIconName: UIApplication.shared.alternateIconName)
    @State private var isPaywallPresented = false
    @State private var isErrorPresented = false

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 16)]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(AppIconOption.allCases) { option in
                        Button {
                            select(option)
                        } label: {
                            AppIconOptionTile(option: option,
                                              isSelected: option == selection,
                                              isLocked: isLocked(option))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.app-icon.\(option.rawValue)")
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPaywallPresented) {
            ProPaywallSheet()
        }
        .alert("App Icon", isPresented: $isErrorPresented) {
        } message: {
            Text("The app icon couldn’t be changed. Try again.")
        }
    }

    private func isLocked(_ option: AppIconOption) -> Bool {
        option.requiresPro && !subscriptionStore.hasProAccess
    }

    private func select(_ option: AppIconOption) {
        guard option != selection else { return }
        guard !isLocked(option) else {
            isPaywallPresented = true
            return
        }

        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(option.alternateIconName)
                selection = option
            } catch {
                AppLog.ui.error("Failed to change the app icon: \(error.localizedDescription, privacy: .public)")
                isErrorPresented = true
            }
        }
    }
}

private struct AppIconOptionTile: View {
    let option: AppIconOption
    let isSelected: Bool
    let isLocked: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(option.previewImageName)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(5)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.gray, in: .circle)
                    }
                }

            Text(option.title)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityValue: String {
        if isSelected {
            String(localized: "Selected")
        } else if isLocked {
            String(localized: "Requires Glassy Desk Pro")
        } else {
            ""
        }
    }
}

#Preview {
    NavigationStack {
        AppIconPickerView()
    }
    .environment(SubscriptionStore())
}
