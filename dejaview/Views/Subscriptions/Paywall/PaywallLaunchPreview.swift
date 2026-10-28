#if DEBUG
import SwiftUI

/// Launch with `-paywallPreview settings` (or any `PaywallSource` value) to open the
/// paywall straight away, for screenshots and QA without tapping through the app.
struct PaywallLaunchPreview: ViewModifier {
    @State private var source = UserDefaults.standard.string(forKey: "paywallPreview")
        .flatMap(PaywallSource.init(rawValue:))

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding { source != nil } set: { if !$0 { source = nil } }) {
            if let source {
                ProPaywallSheet(source: source)
            }
        }
    }
}
#endif
