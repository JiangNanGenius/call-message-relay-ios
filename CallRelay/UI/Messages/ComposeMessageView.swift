import SwiftUI

/// New SMS form. The recipient field accepts pasted numbers; the body is
/// multiline. While the logical submission is in flight the send button and
/// fields are disabled — a failed submission keeps its stable idempotency key
/// and is retried from the conversation view, so a retry can never duplicate
/// the message.
struct ComposeMessageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var inbox: MessageInbox

    var initialRecipient: String = ""

    @State private var recipient = ""
    @State private var bodyText = ""
    @State private var validationMessage: String?
    @FocusState private var recipientFocused: Bool
    @FocusState private var bodyFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("收件人号码", text: $recipient)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($recipientFocused)
                        .disabled(isSending)
                        .accessibilityIdentifier("smsRecipientField")
                    Button {
                        if let clip = UIPasteboard.general.string { recipient = clip }
                    } label: {
                        Label("从剪贴板粘贴收件人", systemImage: "doc.on.clipboard")
                    }
                    .disabled(isSending)
                } header: {
                    Text("收件人")
                }

                Section {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 120)
                        .font(.body)
                        .focused($bodyFocused)
                        .disabled(isSending)
                        .accessibilityLabel("短信正文")
                        .accessibilityIdentifier("smsBodyField")
                    Text("\(bodyText.count)/10000")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } header: {
                    Text("正文")
                } footer: {
                    Text(model.isDemo
                         ? "演示模式：短信只保存在本机内存中，不会联网或真正发送。"
                         : "发送请求成功后按网关真实状态显示（排队/已提交/已发送/失败），不显示虚假送达。")
                        .font(.caption)
                }

                if let reason = liveUnavailableReason {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                } else if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                            .accessibilityIdentifier("smsValidation")
                    }
                }

                Section {
                    Button {
                        send()
                    } label: {
                        HStack {
                            if isSending {
                                ProgressView()
                                Text("发送中…")
                            } else {
                                Label("发送", systemImage: "paperplane.fill")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSend)
                    .accessibilityIdentifier("smsSendButton")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(initialRecipient.isEmpty ? "新建短信" : "回复短信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        recipientFocused = false
                        bodyFocused = false
                    }
                }
            }
            .onAppear {
                recipient = initialRecipient
                if initialRecipient.isEmpty { recipientFocused = true } else { bodyFocused = true }
            }
        }
    }

    private var isSending: Bool {
        // The inbox dedupes, but disabling the control makes duplicate presses
        // impossible in the UI while any unsent entry for this draft is active.
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return inbox.outbox.contains { entry in
            entry.isSending && entry.threadKey == trimmedRecipient && entry.body == trimmedBody
        }
    }

    private var trimmedBody: String {
        String(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000))
    }

    private var liveUnavailableReason: String? {
        model.isDemo ? nil : model.smsUnavailableReason
    }

    private var canSend: Bool {
        if isSending { return false }
        let recipientReady = !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && recipient.count <= 32
        let bodyReady = !trimmedBody.isEmpty
        return recipientReady && bodyReady
    }

    private func send() {
        if let problem = inbox.canStartNewSend(
            to: recipient, body: bodyText, isLineReady: model.isDemo || model.isSMSLineUsable
        ) {
            validationMessage = problem
            return
        }
        let target = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentBody = trimmedBody
        validationMessage = nil
        inbox.send(to: target, body: sentBody, isLineReady: model.isDemo || model.isSMSLineUsable)
        dismiss()
    }
}
