import SwiftUI
import UIKit
import AVFoundation

/// Dedicated engineering diagnostics surface (Settings → 诊断).
///
/// Normal screens stay free of engineering text; this view and the exported
/// file are the only places where event lines appear. Everything listed here
/// is redacted at write time (no tokens, no phone numbers) and the store
/// only ever holds aggregate media counters — never message, contact or
/// audio content.
struct DiagnosticsView: View {
    @ObservedObject private var store = DiagnosticsStore.shared
    @State private var shareURL: IdentifiableURL?
    @State private var showClearConfirm = false
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "版本"), value: versionLine)
                LabeledContent(String(localized: "日志条数"), value: "\(store.entries.count)")
                LabeledContent(String(localized: "麦克风权限"), value: microphoneStatus)
            }

            Section {
                Button {
                    exportFreshSnapshot()
                } label: {
                    HStack {
                        Label(String(localized: "导出诊断日志"), systemImage: "square.and.arrow.up")
                        if isExporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isExporting || (store.entries.isEmpty && store.counters.isEmpty))
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label(String(localized: "清除诊断日志"), systemImage: "trash")
                }
                .disabled(store.entries.isEmpty && store.counters.isEmpty)
            } footer: {
                Text(String(localized: "导出内容仅为本页所示的脱敏事件与聚合计数，每次导出都会生成新的快照。"))
            }

            Section(String(localized: "聚合计数")) {
                if store.counters.isEmpty {
                    Text(String(localized: "暂无记录")).foregroundStyle(.secondary)
                } else {
                    ForEach(store.counters.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent(key, value: "\(value)")
                            .font(.caption.monospaced())
                    }
                }
            }

            Section(String(localized: "最近事件")) {
                if store.entries.isEmpty {
                    Text(String(localized: "暂无记录")).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.entries.suffix(100)).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .lineLimit(3)
                            Text(entry.at.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "诊断"))
        .sheet(item: $shareURL) { item in
            ActivityShareView(url: item.url)
                .ignoresSafeArea()
        }
        .alert(String(localized: "清除诊断日志"), isPresented: $showClearConfirm) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "清除"), role: .destructive) {
                shareURL = nil
                store.clear()
            }
        } message: {
            Text(String(localized: "将删除本机全部诊断事件、计数与已生成的导出文件，且不可恢复。"))
        }
        .alert(String(localized: "导出失败"), isPresented: Binding(
            get: { exportError != nil },
            set: { presented in if !presented { exportError = nil } }
        )) {
            Button(String(localized: "好")) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// One fresh export per tap; nothing is shared when the snapshot fails.
    private func exportFreshSnapshot() {
        isExporting = true
        Task {
            do {
                let url = try await store.exportToFile()
                shareURL = IdentifiableURL(url: url)
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }

    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var microphoneStatus: String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return String(localized: "已允许")
        case .denied: return String(localized: "已拒绝")
        case .undetermined: return String(localized: "未询问")
        @unknown default: return String(localized: "未知")
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: URL { url }
}

/// UIActivityViewController wrapper so the export uses the standard share
/// sheet with a freshly generated, redacted snapshot file.
private struct ActivityShareView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
