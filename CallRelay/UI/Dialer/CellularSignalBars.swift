import SwiftUI

/// True cellular signal bars for the gateway SIM: 0–4 filled bars from the
/// modem's own report. Nothing is inferred from gateway connectivity, and a
/// missing/stale report renders neutral empty bars — never fabricated fill.
struct CellularSignalBars: View {
    /// Bars reported by the gateway modem (`signal.bars`), nil when unknown.
    let bars: Int?

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                    .frame(width: 3, height: 5 + CGFloat(index) * 2.5)
                    .foregroundStyle(index < filledCount ? filledColor : Color(UIColor.quaternaryLabel))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var filledCount: Int {
        guard let bars, bars > 0 else { return 0 }
        return min(bars, 4)
    }

    private var filledColor: Color {
        // Known zero/one bar is a real weak-signal state; keep it legible but
        // not alarming. Unknown (nil) stays fully neutral.
        filledCount >= 2 ? .secondary : .orange
    }

    private var accessibilityText: String {
        guard let bars else { return "蜂窝信号未知" }
        if bars <= 0 { return "蜂窝信号无服务" }
        return "蜂窝信号 \(min(bars, 4)) 格"
    }
}
