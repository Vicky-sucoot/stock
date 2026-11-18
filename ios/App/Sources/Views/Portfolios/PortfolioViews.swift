import DCACore
import DCAKit
import SwiftUI

struct PortfolioListView: View {
    @EnvironmentObject var model: AppModel
    @State private var creating = false
    @State private var showArchived = false

    var body: some View {
        let _ = model.revision
        let all = model.book.data.portfolios.sorted { $0.sortOrder < $1.sortOrder }
        List {
            ForEach(all.filter { showArchived || $0.archivedAt == nil }) { p in
                NavigationLink { PortfolioDetailView(portfolioId: p.id) } label: {
                    HStack {
                        Circle().fill(Color(hex: p.colorHex)).frame(width: 10, height: 10)
                        Text(p.name)
                        if p.archivedAt != nil { Text("已封存").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Toggle("顯示已封存", isOn: $showArchived)
        }
        .navigationTitle("投資組合")
        .toolbar { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("新增投資組合") }
        .sheet(isPresented: $creating) { PortfolioEditView(existing: nil) }
    }
}

struct PortfolioEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let existing: Portfolio?

    @State private var name = ""
    @State private var note = ""
    @State private var color = "#3B82F6"
    @State private var currency = "TWD"
    @State private var include = true

    static let colors = ["#3B82F6", "#EF4444", "#10B981", "#F59E0B", "#8B5CF6", "#6B7280"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("名稱（1～20 字）", text: $name)
                TextField("說明（選填）", text: $note)
                Picker("顏色", selection: $color) {
                    ForEach(Self.colors, id: \.self) { c in Circle().fill(Color(hex: c)).frame(width: 14, height: 14).tag(c) }
                }
                Picker("預設幣別", selection: $currency) {
                    ForEach(["TWD", "USD", "JPY"], id: \.self) { Text($0) }
                }
                Toggle("納入首頁合併總覽", isOn: $include)
            }
            .navigationTitle(existing == nil ? "新增投資組合" : "編輯投資組合")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { save() } }
            }
            .onAppear {
                guard let p = existing else { return }
                name = p.name
                note = p.note ?? ""
                color = p.colorHex
                currency = p.defaultCurrency
                include = p.includeInOverview
            }
        }
    }

    private func save() {
        let ok: Void?
        if var p = existing {
            p.name = name
            p.note = note.isEmpty ? nil : note
            p.colorHex = color
            p.defaultCurrency = currency
            p.includeInOverview = include
            ok = model.mutate { try $0.updatePortfolio(p) }
        } else {
            ok = model.mutate { _ = try $0.createPortfolio(name: name, note: note.isEmpty ? nil : note, colorHex: color,
                                                           defaultCurrency: currency, includeInOverview: include) }
        }
        if ok != nil { dismiss() }
    }
}

struct PortfolioDetailView: View {
    @EnvironmentObject var model: AppModel
    let portfolioId: UUID
    @State private var section = 0
    @State private var editing = false
    @State private var newPlan = false
    @State private var newTx = false
    @State private var confirmDelete = false
    @State private var deletePin = ""

    var body: some View {
        let _ = model.revision
        let book = model.book
        if let p = book.data.portfolios.first(where: { $0.id == portfolioId }) {
            List {
                Picker("", selection: $section) {
                    Text("持有").tag(0)
                    Text("計畫").tag(1)
                    Text("交易").tag(2)
                }
                .pickerStyle(.segmented)
                switch section {
                case 0: holdings
                case 1: plans
                default: transactions
                }
            }
            .navigationTitle(p.name)
            .toolbar {
                Menu {
                    Button("新增定期定額計畫") { newPlan = true }
                    Button("新增交易／股利／費用") { newTx = true }
                    Button("編輯組合") { editing = true }
                    Button(p.archivedAt == nil ? "封存" : "取消封存") { model.mutate { try $0.setArchived(p.id, p.archivedAt == nil) } }
                    Button("刪除組合", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .sheet(isPresented: $editing) { PortfolioEditView(existing: p) }
            .sheet(isPresented: $newPlan) { PlanEditView(portfolioId: p.id, existing: nil) }
            .sheet(isPresented: $newTx) { TransactionEditView(portfolioId: p.id, existing: nil) }
            .alert("刪除「\(p.name)」？", isPresented: $confirmDelete) {
                SecureField("輸入 App 密碼", text: $deletePin)
                Button("刪除", role: .destructive) { delete(p.id) }
                Button("取消", role: .cancel) { deletePin = "" }
            } message: {
                Text("會一併刪除這個組合的計畫與交易紀錄。資料只存在本機，刪除後無法還原。")
            }
        } else {
            ContentUnavailableView("找不到投資組合", systemImage: "folder")
        }
    }

    private func delete(_ id: UUID) {
        let pin = deletePin
        deletePin = ""
        do {
            try model.passcode.unlock(pin)
            model.mutate { try $0.deletePortfolio(id) }
        } catch {
            model.errorMessage = SecurityText.describe(error)
        }
    }

    @ViewBuilder private var holdings: some View {
        let book = model.book
        let groups = Dictionary(grouping: book.data.transactions.filter { $0.portfolioId == portfolioId }) { $0.instrumentId }
        if groups.isEmpty { Text("尚無交易紀錄").foregroundStyle(.secondary) }
        ForEach(Array(groups.keys), id: \.self) { iid in
            if let inst = book.instrument(iid),
               let pos = try? buildPosition(groups[iid]!.map { try $0.coreTransaction() }) {
                let (price, src) = book.currentPrice(inst)
                NavigationLink { InstrumentDetailView(instrumentId: iid, portfolioId: portfolioId) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(inst.symbol) \(inst.name)").lineLimit(1)
                            Spacer()
                            if let price { Text(Fmt.money(pos.quantity * price, inst.currency)).monospacedDigit() }
                        }
                        HStack(spacing: 8) {
                            Text("數量 \(Fmt.quantity(pos.quantity))")
                            Text("均價 \(Fmt.number(pos.avgCost))")
                            Text("現價 \(Fmt.number(price))")
                            if src == .manual { Tag(text: "手動") }
                            if let price, pos.costBasis > 0 {
                                Text(Fmt.percent((pos.quantity * price - pos.costBasis) / pos.costBasis))
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var plans: some View {
        let ps = model.book.data.plans.filter { $0.portfolioId == portfolioId }
        if ps.isEmpty { Text("尚無定期定額計畫").foregroundStyle(.secondary) }
        ForEach(ps) { plan in
            NavigationLink { PlanEditView(portfolioId: portfolioId, existing: plan) } label: {
                VStack(alignment: .leading) {
                    Text(model.book.instrument(plan.instrumentId).map { "\($0.symbol) \($0.name)" } ?? "?")
                    Text(PlanText.summary(plan)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var transactions: some View {
        let txs = model.book.transactions(portfolioId: portfolioId)
        if txs.isEmpty { Text("尚無交易紀錄").foregroundStyle(.secondary) }
        ForEach(txs) { tx in
            NavigationLink { TransactionEditView(portfolioId: portfolioId, existing: tx) } label: { TransactionRow(tx: tx) }
        }
    }
}

struct TransactionRow: View {
    @EnvironmentObject var model: AppModel
    let tx: TransactionRecord

    var body: some View {
        let inst = model.book.instrument(tx.instrumentId)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Fmt.shortDate(tx.tradeDate)).monospacedDigit()
                Text(TxText.name(tx.type)).bold()
                Text(inst?.symbol ?? "")
                Spacer()
                Text(Fmt.money(tx.grossAmount.value, tx.currency)).monospacedDigit()
            }
            if let q = tx.quantity?.value {
                Text("\(Fmt.quantity(q)) × \(Fmt.number(tx.price?.value))　費用 \(Fmt.number(tx.fee.value + tx.tax.value + tx.otherCost.value))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct InstrumentDetailView: View {
    @EnvironmentObject var model: AppModel
    let instrumentId: UUID
    let portfolioId: UUID
    @State private var editingPrice = false

    var body: some View {
        let _ = model.revision
        let book = model.book
        if let inst = book.instrument(instrumentId) {
            let (price, src) = book.currentPrice(inst)
            let cache = book.data.priceCache[inst.id.uuidString]
            List {
                Section("價格") {
                    LabeledContent("目前採用", value: "\(Fmt.number(price))\(src == .manual ? "（手動）" : "")")
                    if let cache {
                        LabeledContent("自動參考值", value: "\(Fmt.number(cache.value.value))（資料日 \(Fmt.shortDate(cache.dataDate))）")
                        Text(cache.attribution).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("手動設定價格\(inst.assetType == "FUND" ? "／淨值" : "")") { editingPrice = true }
                    if src == .manual {
                        Button("改回自動") { model.mutate { try $0.revertToAuto(key: inst.id.uuidString) } }
                    }
                }
                Section("交易紀錄") {
                    ForEach(book.transactions(portfolioId: portfolioId, instrumentId: instrumentId)) { TransactionRow(tx: $0) }
                }
            }
            .navigationTitle("\(inst.symbol) \(inst.name)")
            .sheet(isPresented: $editingPrice) { ManualValueSheet(kind: .price(inst)) }
        }
    }
}

enum TxText {
    static func name(_ raw: String) -> String {
        switch TxType(rawValue: raw) {
        case .buy: return "買入"
        case .sell: return "賣出"
        case .dividendCash: return "現金股利"
        case .dividendStock: return "股票股利"
        case .dividendReinvest: return "股利再投入"
        case .fee: return "費用"
        case .splitAdjust: return "分割調整"
        case .none: return raw
        }
    }
}

enum PlanText {
    static func summary(_ p: PlanRecord) -> String {
        let amount = p.amountMode == .amount ? Fmt.money(p.amount.value, p.currency) : "\(Fmt.quantity(p.amount.value)) 單位"
        let when: String
        switch p.frequency {
        case "WEEKLY":
            let names = ["", "一", "二", "三", "四", "五", "六", "日"]
            when = "每週" + p.weekdays.sorted().map { names[$0] }.joined(separator: "、")
        case "MONTHLY": when = "每月 " + p.monthDays.sorted().map(String.init).joined(separator: "、") + " 日"
        default: when = "指定日期 \(p.specificDates.count) 天"
        }
        return "\(when)・\(amount)\(p.paused ? "・暫停中" : "")"
    }
}
