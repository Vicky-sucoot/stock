import SwiftUI

/// 4 位數密碼輸入：4 個圓點加數字鍵盤。輸入滿 4 碼時呼叫 onComplete。
struct PasscodePad: View {
    let title: String
    var subtitle: String? = nil
    var disabled = false
    let onComplete: (String) -> Void

    @State private var entered = ""

    var body: some View {
        VStack(spacing: 24) {
            Text(title).font(.title3.bold())
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .strokeBorder(.primary, lineWidth: 1.5)
                        .background(Circle().fill(i < entered.count ? Color.primary : .clear))
                        .frame(width: 16, height: 16)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("已輸入 \(entered.count) 位")
            grid
        }
        .padding()
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private var grid: some View {
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]
        return VStack(spacing: 14) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 72, height: 72)
                        } else {
                            Button { tap(key) } label: {
                                Text(key).font(.title)
                                    .frame(width: 72, height: 72)
                                    .background(Circle().fill(Color.secondary.opacity(key == "⌫" ? 0 : 0.15)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(key == "⌫" ? "刪除" : key)
                        }
                    }
                }
            }
        }
    }

    private func tap(_ key: String) {
        if key == "⌫" {
            if !entered.isEmpty { entered.removeLast() }
            return
        }
        guard entered.count < 4 else { return }
        entered.append(key)
        if entered.count == 4 {
            let pin = entered
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                entered = ""
                onComplete(pin)
            }
        }
    }
}
