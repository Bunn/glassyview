import SwiftUI

struct RevenueCatUnavailableView: View {
    var body: some View {
        ContentUnavailableView("Purchases Unavailable",
                               systemImage: "exclamationmark.triangle",
                               description: Text("Purchases are temporarily unavailable. Please try again later."))
    }
}
