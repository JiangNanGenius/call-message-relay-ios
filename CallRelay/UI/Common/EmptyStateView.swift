import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var accessibilityIdentifier: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ifLet(accessibilityIdentifier) { view, id in
            view.accessibilityIdentifier(id)
        }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value { transform(self, value) } else { self }
    }
}
