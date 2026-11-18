import DCAKit
import SwiftUI

/// 選擇標的：台股與台灣 ETF 從官方清單搜尋；美股、日股、基金可手動新增（docs/04 instrument）。
struct InstrumentPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onPick: (Instrument) -> Void

    @State private var query = ""
    @State private var market = Market.tw
    @State private var manualSymbol = ""
    @State private var manualName = ""
    @State private var manualType = "STOCK"

    var body: some View {
        NavigationStack {
            List {
                Picker("市場", selection: $market) {
                    Text("台股").tag(Market.tw)
                    Text("美股").tag(Market.us)
                    Text("日股").tag(Market.jp)
                    Text("基金").tag(Market.fundTW)
                }
                .pickerStyle(.segmented)

                let existing = model.book.data.instruments.filter { $0.market == market && matches($0.symbol, $0.name) }
                if !existing.isEmpty {
                    Section("已使用") {
                        ForEach(existing) { inst in
                            Button("\(inst.symbol) \(inst.name)") { pick(inst) }
                        }
                    }
                }
                if market == Market.tw {
                    Section {
                        if model.listing.isEmpty {
                            HStack { ProgressView(); Text("載入官方清單…") }
                        }
                        ForEach(model.listing.filter { matches($0.symbol, $0.name) }.prefix(50), id: \.symbol) { l in
                            Button {
                                if let inst = model.mutate({ try $0.upsertInstrument(market: Market.tw, symbol: l.symbol, name: l.name,
                                                                                     assetType: l.symbol.hasPrefix("00") ? "ETF" : "STOCK",
                                                                                     board: l.board) }) {
                                    pick(inst)
                                }
                            } label: {
                                HStack {
                                    Text("\(l.symbol) \(l.name)")
                                    Spacer()
                                    Text(l.board == "TWSE" ? "上市" : "上櫃").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("證交所／櫃買中心清單") }
                } else {
                    Section {
                        TextField(market == Market.fundTW ? "基金代碼（自訂）" : "代號，例如 AAPL、7203", text: $manualSymbol)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        TextField("名稱", text: $manualName)
                        if market != Market.fundTW {
                            Picker("類型", selection: $manualType) {
                                Text("股票").tag("STOCK")
                                Text("ETF").tag("ETF")
                            }
                        }
                        Button("新增") {
                            let type = market == Market.fundTW ? "FUND" : manualType
                            if let inst = model.mutate({ try $0.upsertInstrument(market: market, symbol: manualSymbol,
                                                                                 name: manualName.isEmpty ? manualSymbol : manualName,
                                                                                 assetType: type,
                                                                                 isUserDefined: market != Market.us) }) {
                                pick(inst)
                            }
                        }
                        .disabled(manualSymbol.isEmpty)
                    } header: { Text("手動新增") } footer: {
                        Text(market == Market.us
                             ? "美股價格需在設定中輸入你自己的 Finnhub API 金鑰才會自動更新；否則請手動輸入價格。"
                             : "日股與基金目前沒有可用的免費自動來源，請手動輸入價格或淨值。")
                    }
                }
            }
            .searchable(text: $query, prompt: "代號或名稱")
            .navigationTitle("選擇標的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await model.loadListingIfNeeded() }
        }
    }

    private func matches(_ symbol: String, _ name: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || symbol.localizedCaseInsensitiveContains(q) || name.localizedCaseInsensitiveContains(q)
    }

    private func pick(_ inst: Instrument) {
        onPick(inst)
        dismiss()
    }
}
