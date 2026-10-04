import SwiftUI

/// Compact native suggestion rows (avatar + name + resolved phone) shared by
/// the SMS compose To-field and the dialer keypad. A multi-number contact
/// expands in place to per-number rows on tap — a number is only ever filled
/// by an explicit choice, never silently.
struct ContactSuggestionList: View {
    /// Collapsed suggestion rows (one per contact).
    let suggestions: [ContactSuggestion]
    /// Per-number rows for the expanded multi-number contact, if any.
    let expandedNumbers: [ContactSuggestion]?
    let onFill: (ContactSuggestion) -> Void
    let onExpand: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                VStack(spacing: 0) {
                    if index > 0 { Divider().padding(.leading, 54) }
                    if suggestion.hasMultipleNumbers,
                       expandedNumbers?.first?.contactID == suggestion.contactID {
                        expandedNumberRows
                    } else {
                        row(suggestion)
                    }
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("contactSuggestions")
    }

    private func row(_ suggestion: ContactSuggestion) -> some View {
        Button {
            if suggestion.hasMultipleNumbers {
                onExpand(suggestion.contactID)
            } else {
                onFill(suggestion)
            }
        } label: {
            HStack(spacing: 10) {
                suggestionAvatar(suggestion.name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(suggestion.hasMultipleNumbers
                         ? String(localized: "多个号码，点选其中一个")
                         : suggestion.labeledPhone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if suggestion.hasMultipleNumbers {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(suggestion.hasMultipleNumbers
                           ? "该联系人有多个号码"
                           : "使用号码 \(suggestion.phone)")
    }

    /// Per-number rows for the expanded contact; the collapsed row stays as
    /// a fallback so nothing becomes untappable if the list is empty.
    private var expandedNumberRows: some View {
        Group {
            if let numbers = expandedNumbers, !numbers.isEmpty {
                ForEach(numbers, id: \.id) { number in
                    Button {
                        onFill(number)
                    } label: {
                        HStack(spacing: 10) {
                            suggestionAvatar(number.name)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(number.name).font(.body).foregroundStyle(.primary).lineLimit(1)
                                Text(number.labeledPhone).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .padding(.leading, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else if let fallback = suggestions.first(where: { $0.hasMultipleNumbers }) {
                row(fallback)
            }
        }
    }
}

extension ContactSuggestionList {
    /// Pure selection semantics, unit-tested: tapping a suggestion either
    /// fills the number immediately or expands the contact's number list.
    static func selectionAction(for suggestion: ContactSuggestion) -> SelectionAction {
        suggestion.hasMultipleNumbers ? .expand(suggestion.contactID) : .fill(suggestion)
    }

    enum SelectionAction: Equatable {
        case fill(ContactSuggestion)
        case expand(String)
    }

    /// Suggestions stay visible while the query is a partial fragment; once
    /// the text IS a contact's exact number the list dismisses itself.
    static func shouldShowSuggestions(suggestions: [ContactSuggestion], query: String) -> Bool {
        guard !suggestions.isEmpty else { return false }
        let digits = PhoneNormalizer.digits(query)
        guard !digits.isEmpty else { return true }
        let exact = suggestions.contains { PhoneNormalizer.digits($0.phone) == digits }
        return !exact
    }
}

private func suggestionAvatar(_ name: String) -> some View {
    Circle()
        .fill(Color(.systemGray3))
        .frame(width: 30, height: 30)
        .overlay(
            Text(name.first.map(String.init) ?? "?")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        )
}
