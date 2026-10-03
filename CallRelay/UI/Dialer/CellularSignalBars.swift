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
                    .foregroundStyle(index < filledCount ? filledColor : emptyColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Filled slots for the reported count, clamped to the four rendered
    /// slots; nil/unknown and out-of-range reports never fabricate fill.
    var filledCount: Int {
        guard let bars, bars > 0 else { return 0 }
        return min(bars, 4)
    }

    /// Filled bars use the highest-contrast label color so the indicator
    /// reads as a strong dark glyph in light mode and a bright glyph in dark
    /// mode — never a washed-out gray.
    private var filledColor: Color { .primary }

    /// Empty slots stay distinctly pale/muted but keep accessible contrast
    /// against any cell background in both schemes.
    private var emptyColor: Color { Color(UIColor.tertiarySystemFill) }

    private var accessibilityText: String {
        guard let bars else { return "蜂窝信号未知" }
        if bars <= 0 { return "蜂窝信号无服务" }
        return "蜂窝信号 \(min(bars, 4)) 格"
    }
}

#Preview("0 格") {
    CellularSignalBars(bars: 0)
        .padding()
}

#Preview("1 格") {
    CellularSignalBars(bars: 1)
        .padding()
}

#Preview("2 格") {
    CellularSignalBars(bars: 2)
        .padding()
}

#Preview("3 格") {
    CellularSignalBars(bars: 3)
        .padding()
}

#Preview("4 格") {
    CellularSignalBars(bars: 4)
        .padding()
}

#Preview("未知") {
    CellularSignalBars(bars: nil)
        .padding()
}
