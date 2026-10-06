import SwiftUI

/// New SMS sheet, modeled on the system Messages compose: compact "收件人"
/// and "发件线路" rows at the top, the conversation area below, and an
/// inline capsule composer pinned above the keyboard. Recipient paste uses
/// the field's standard edit menu plus a small clipboard affordance (no
/// oversized paste row). While the logical submission is in flight the send
/// button and fields are disabled — a failed submission keeps its stable
/// idempotency key and is retried from the conversation view on the SAME
/// original line, so a retry can never duplicate the message or switch SIMs.
struct ComposeMessageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var inbox: MessageInbox

    var initialRecipient: String = ""
    /// Shortcuts compose handoff prefill: body text and an explicit
    /// originating line. Both remain editable; nothing sends until the
    /// explicit in-app confirmation.
    var initialBody: String = ""
    var initialLineID: String? = nil
    /// Set when the shortcut's saved line expired (pairing changed / line
    /// revoked): the draft is kept, this notice explains why, and sending is
    /// gated on an explicit From-line pick — never a silent default send.
    var lineExpiredMessage: String? = nil

    @State private var recipient = ""
    @State private var bodyText = ""
    @State private var chosenLineID: String? = nil
    @State private var validationMessage: String?
    /// Shortcuts expired-line gate: set when lineExpiredMessage arrives;
    /// cleared only by an EXPLICIT From-line pick, never by the default.
    @State private var requiresLineRepick = false
    @State private var expandedContactID: String?
    @FocusState private var recipientFocused: Bool
    @FocusState private var bodyFocused: Bool

    /// Contact autocomplete under the To row: Latin name, full pinyin or
    /// syllable-initial match (multilingual keyboard) over the snapshot's
    /// cached pinyin index. Dismisses itself once the text IS an exact
    /// contact number; free text is never auto-committed.
    private var recipientSuggestions: [ContactSuggestion] {
        model.contacts.searchContacts(query: recipient)
    }

    private var showSuggestions: Bool {
        recipientFocused
            && ContactSuggestionList.shouldShowSuggestions(suggestions: recipientSuggestions,
                                                           query: recipient)
    }

    private var resolvedLineID: String? { chosenLineID ?? model.defaultLineId }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                recipientRow
                if showSuggestions {
                    ContactSuggestionList(
                        suggestions: recipientSuggestions,
                        expandedNumbers: expandedContactID.map {
                            ContactAutocomplete.numbers(for: $0, in: model.contacts.contacts)
                        },
                        onFill: { suggestion in
                            recipient = suggestion.phone
                            expandedContactID = nil
                            // Keep focus so the owner can keep typing the body
                            // after choosing; the exact-number rule dismisses
                            // the list itself.
                        },
                        onExpand: { contactID in
                            expandedContactID = expandedContactID == contactID ? nil : contactID
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Divider().padding(.leading, 76)
                fromLineRow
                Divider()
                Spacer(minLength: 0)
                if let lineExpiredMessage {
                    validationBanner(lineExpiredMessage, color: .orange,
                                     icon: "exclamationmark.triangle.fill")
                        .accessibilityIdentifier("smsLineExpiredNotice")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                } else if let reason = liveUnavailableReason {
                    validationBanner(reason, color: .orange, icon: "exclamationmark.triangle.fill")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                } else if let validationMessage {
                    validationBanner(validationMessage, color: .red,
                                     icon: "exclamationmark.triangle.fill")
                        .accessibilityIdentifier("smsValidation")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
                composer
            }
            .background(Color(.systemBackground))
            .navigationTitle(initialRecipient.isEmpty ? "新信息" : "回复短信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSending)
                }
            }
            .onAppear {
                recipient = initialRecipient
                bodyText = initialBody
                // An intent-supplied line is only a prefill: it is validated
                // against the live authorized list by the From-line menu and
                // the send path, never trusted blindly.
                chosenLineID = initialLineID ?? model.defaultLineId
                requiresLineRepick = lineExpiredMessage != nil
                if initialRecipient.isEmpty { recipientFocused = true } else { bodyFocused = true }
            }
        }
    }

    // MARK: To row (compact)

    private var recipientRow: some View {
        HStack(spacing: 8) {
            Text("收件人")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 16)
            // The To field accepts BOTH contact names (Chinese characters,
            // pinyin/Latin letters — the matcher folds case/diacritics/width)
            // and phone numbers, so it must use the normal multilingual
            // keyboard: a digits-only .phonePad made name autocomplete
            // unreachable. The dialer keypad stays digits-only by design;
            // name search is not offered there. No textContentType lets the
            // owner type free-form names without a phone-number QuickType
            // suggestion overriding them.
            TextField("姓名或号码", text: $recipient)
                .keyboardType(.default)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($recipientFocused)
                .disabled(isSending)
                .accessibilityIdentifier("smsRecipientField")
                // Paste comes from the field's standard edit menu
                // (long-press); no standalone clipboard affordance —
                // the user asked to remove it as jarring.
                .padding(.trailing, 16)
        }
        .padding(.vertical, 10)
    }

    // MARK: From row (dual-SIM line, compact)

    @ViewBuilder
    private var fromLineRow: some View {
        if model.authorizedLines.contains(where: { $0.permissions.sendSms }) {
            HStack(spacing: 8) {
                // Apple's native label is 发件人 (From); intrinsic width
                // keeps it one line at default Dynamic Type while still
                // expanding with accessibility sizes.
                Text("发件人")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 16)
                Menu {
                    ForEach(model.authorizedLines.filter(\.permissions.sendSms)) { line in
                        Button {
                            chosenLineID = line.id
                            // Any explicit pick satisfies the expired-line
                            // re-pick requirement (including re-confirming
                            // the displayed default).
                            requiresLineRepick = false
                        } label: {
                            Label(lineLabel(line),
                                  systemImage: resolvedLineID == line.id ? "checkmark" : "")
                        }
                        .disabled(!line.enabled)
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let line = model.line(for: resolvedLineID) {
                            Text(line.name).foregroundStyle(.primary)
                            if let number = line.phoneNumber, !number.isEmpty {
                                Text("· \(number)")
                                    .foregroundStyle(.secondary)
                                    .privacySensitive()
                            }
                        } else {
                            Text("默认线路").foregroundStyle(.primary)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.body)
                }
                .accessibilityIdentifier("composeLineMenu")
                Spacer()
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $bodyText)
                .font(.body)
                .frame(minHeight: 36, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .focused($bodyFocused)
                .disabled(isSending)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.secondarySystemBackground))
                        if bodyText.isEmpty {
                            Text("信息·短信")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 20)
                                .allowsHitTesting(false)
                        }
                    }
                )
                .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
                .accessibilityLabel("短信正文")
                .accessibilityIdentifier("smsBodyField")

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Color.accentColor : Color.gray.opacity(0.4),
                                in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("smsSendButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func validationBanner(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func lineLabel(_ line: AuthorizedLine) -> String {
        if let number = line.phoneNumber, !number.isEmpty {
            return "\(line.name) · \(number)"
        }
        return line.name
    }

    private var isSending: Bool {
        // The inbox dedupes, but disabling the control makes duplicate presses
        // impossible in the UI while any unsent entry for this draft is active.
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return inbox.outbox.contains { entry in
            entry.isSending && entry.to == trimmedRecipient && entry.body == trimmedBody
        }
    }

    private var trimmedBody: String {
        String(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000))
    }

    /// Readiness follows the CHOSEN line (not whatever the app default is):
    /// a line the user explicitly picked is never silently replaced.
    private var liveUnavailableReason: String? {
        if model.isDemo { return nil }
        return model.lineSMSUnavailableReason(resolvedLineID)
    }

    private var canSend: Bool {
        if isSending { return false }
        // A shortcut whose saved line expired requires an EXPLICIT From-line
        // pick first: the default line is never silently used for that send.
        if requiresLineRepick { return false }
        let recipientReady = !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && recipient.count <= 32
        let bodyReady = !trimmedBody.isEmpty
        return recipientReady && bodyReady
    }

    private func send() {
        let target = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = inbox.canStartNewSend(
            to: target, body: bodyText, isLineReady: model.isDemo || model.lineCanSendSMS(resolvedLineID)
        ) {
            validationMessage = problem
            return
        }
        let sentBody = trimmedBody
        validationMessage = nil
        // Persist the explicit choice for this conversation so replies and
        // retries reuse the same line/number. Keyed by the canonical
        // `lineID:peer` form: the conversation view reads that same key, so
        // the choice actually follows the thread (a bare recipient key was
        // invisible to the conversation and vice versa).
        model.setPreferredLine(chosenLineID,
                               for: ThreadKey.canonical(lineID: resolvedLineID, peer: target))
        inbox.send(to: target, body: sentBody,
                   isLineReady: model.isDemo || model.lineCanSendSMS(resolvedLineID),
                   lineId: resolvedLineID)
        dismiss()
    }
}
