import SwiftUI

struct DialerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var number = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
    private let keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                LineStatusHeader()

                Spacer(minLength: 4)

                TextField("输入号码", text: $number)
                    .keyboardType(.phonePad)
                    .multilineTextAlignment(.center)
                    .textContentType(.telephoneNumber)
                    .onChange(of: number) { _, value in
                        let filtered = String(value.filter { "0123456789+*#".contains($0) }.prefix(32))
                        if filtered != value { number = filtered }
                    }
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(height: 44)
                    .accessibilityLabel(number.isEmpty ? "号码输入框" : number)

                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(keys, id: \.self) { key in
                        DialKey(label: key) { append(key) }
                            .contextMenu {
                                if key == "0" { Button("输入 +") { append("+") } }
                            }
                    }
                }
                .padding(.horizontal, 40)

                HStack {
                    Color.clear.frame(width: 64, height: 64)
                    Spacer()
                    Button {
                        model.dial(number)
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(canDial ? Color.green : Color.gray.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .disabled(!canDial)
                    .accessibilityLabel("拨打")
                    Spacer()
                    Button {
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title2)
                            .frame(width: 64, height: 44)
                    }
                    .disabled(number.isEmpty)
                    .accessibilityLabel("删除一位")
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 8)
            }
            .padding(.bottom, 12)
            .navigationTitle("拨号")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var canDial: Bool {
        !number.trimmingCharacters(in: .whitespaces).isEmpty
            && (model.isDemo || model.isLineUsable)
    }

    private func append(_ key: String) {
        if number.count < 32 { number.append(key) }
    }
}

struct DialKey: View {
    let label: String
    let action: () -> Void

    private var subtitle: String {
        switch label {
        case "2": return "ABC"
        case "3": return "DEF"
        case "4": return "GHI"
        case "5": return "JKL"
        case "6": return "MNO"
        case "7": return "PQRS"
        case "8": return "TUV"
        case "9": return "WXYZ"
        case "0": return "+"
        default: return ""
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label).font(.title)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .background(Color(.secondarySystemFill))
            .clipShape(Circle())
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(VoiceOverKey(label))
    }

    private func VoiceOverKey(_ key: String) -> String {
        key == "*" ? "星号" : key == "#" ? "井号" : key
    }
}

struct LineStatusHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(model.linePhase.summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(color)
                    .multilineTextAlignment(.center)
            }
            if !model.gatewayName.isEmpty {
                Text(model.gatewayName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var icon: String {
        switch model.linePhase {
        case .unpaired: return "slash.circle"
        case .demo: return "wand.and.stars"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .online: return "dot.radiowaves.left.and.right"
        case .offline: return "wifi.slash"
        }
    }

    private var color: Color {
        switch model.linePhase {
        case .online(let line):
            return line.registration == .registered ? .green : .orange
        case .demo: return .purple
        case .offline, .unpaired: return .secondary
        case .connecting: return .orange
        }
    }
}
