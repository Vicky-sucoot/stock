import Charts
import DCACore
import DCAKit
import SwiftUI

/// 首頁（docs/03 §2）：定期定額 → 資產 KPI → 月損益圖 → 匯率 → 資產配置 → 投資組合 → 平均成本 → 資料狀態。
struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let _ = model.revision
        let result = model.book.overview(view: model.viewCurrency)
        List {
            Section { PlanCard(pending: result.pending) }
            Section { KPICard(ov: result.overview) }
            Section("損益走勢（每月）") { MonthlyChart() }
            Section("匯率") { FxCard() }
            if !result.overview.rows.isEmpty {
                Section("資產配置") { AllocationView(ov: result.overview) }
            }
            Section("投資組合") { PortfolioSummaryRows() }
            if !result.overview.rows.isEmpty {
                Section("持有標的平均成本") { HoldingsRows(ov: result.overview) }
            }
            Section { DataStatusRow(ov: result.overview, broken: result.brokenHoldings) }
        }
        .navigationTitle("總覽")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("幣別", selection: $model.viewCurrency) {
                    Text("TWD").tag("TWD")
                    Text("USD").tag("USD")
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.refresh(force: true) } } label: {
                    if model.refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .accessibilityLabel("更新行情")
            }
        }
        .refreshable { await model.refresh(force: true) }
    }
}

struct PlanCard: View {
    @EnvironmentObject var model: AppModel
    let pending: PendingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("定期定額").font(.headline)
            if pending.count > 0 {
                NavigationLink { PendingListView() } label: {
                    HStack {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("\(pending.count) 筆待確認，約 \(Fmt.money(pending.estimatedTotal, model.viewCurrency))")
                        if pending.unconvertibleCount > 0 {
                            Text("（\(pending.unconvertibleCount) 筆無法估算）").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("目前沒有待確認的期數").foregroundStyle(.secondary)
            }
            let upcoming = upcomingWeek()
            if !upcoming.isEmpty {
                Text("近 7 天").font(.subheadline.bold()).padding(.top, 4)
                ForEach(upcoming) { item in
                    HStack {
                        Text(Fmt.shortDate(item.date)).monospacedDigit()
                        Text(item.title).lineLimit(1)
                        Spacer()
                        Text(item.amount).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    struct UpcomingItem: Identifiable {
        let id: String
        let date: String
        let title: String
        let amount: String
    }

    private func upcomingWeek() -> [UpcomingItem] {
        let book = model.book
        var out: [UpcomingItem] = []
        for plan in book.data.plans where !plan.paused {
            guard let inst = book.instrument(plan.instrumentId) else { continue }
            let limit = book.today(market: inst.market).adding(days: 7)
            for o in (try? book.previewUpcoming(plan, count: 3)) ?? [] where o.scheduledDate <= limit {
                let pname = book.data.portfolios.first { $0.id == plan.portfolioId }?.name ?? ""
                let amount = plan.amountMode == .amount ? Fmt.money(plan.amount.value, plan.currency) : "\(Fmt.quantity(plan.amount.value)) 單位"
                out.append(UpcomingItem(id: "\(plan.id)-\(o.periodKey)", date: o.scheduledDate.iso,
                                        title: "\(pname)・\(inst.name)", amount: amount))
            }
        }
        return out.sorted { $0.date < $1.date }
    }
}

struct KPICard: View {
    @EnvironmentObject var model: AppModel
    let ov: Overview

    var body: some View {
        let ccy = model.viewCurrency
        let pnl = model.includeDividends ? ov.pnlIncDiv : ov.pnlExDiv
        let ret = model.includeDividends ? ov.returnIncDiv : ov.returnExDiv
        VStack(alignment: .leading, spacing: 8) {
            Text("總資產").font(.subheadline).foregroundStyle(.secondary)
            Text(Fmt.money(ov.totalAssets, ccy)).font(.largeTitle.bold()).monospacedDigit().privacySensitive()
            HStack {
                kpi("累計投入", Fmt.money(ov.investedCurrent, ccy))
                kpi("損益", Fmt.signedMoney(pnl, ccy), color: pnl >= 0 ? .red : .green)
                kpi("報酬率", Fmt.percent(ret), color: (ret ?? 0) >= 0 ? .red : .green)
            }
            Toggle("損益含股利", isOn: $model.includeDividends).font(.footnote)
            Text("報酬率 = 損益 ÷ 歷史總投入 \(Fmt.money(ov.historicalInvested, ccy))；台股慣例紅漲綠跌")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func kpi(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.bold()).foregroundStyle(color).monospacedDigit().privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MonthlyChart: View {
    @EnvironmentObject var model: AppModel
    @State private var usdOriginalOnly = false
    @State private var selected: String?

    var body: some View {
        let _ = model.revision
        let pts = (try? model.book.monthlyPoints(view: model.viewCurrency,
                                                 onlyCurrency: model.viewCurrency == "USD" && usdOriginalOnly ? "USD" : nil)) ?? []
        VStack(alignment: .leading) {
            if model.viewCurrency == "USD" {
                Toggle("只看美元計價資產（原幣、不換算）", isOn: $usdOriginalOnly).font(.footnote)
            }
            if pts.isEmpty {
                Text("新增交易後會顯示每月走勢").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(pts, id: \.month) { p in
                        LineMark(x: .value("月份", p.month), y: .value("金額", (p.marketValue as NSDecimalNumber).doubleValue),
                                 series: .value("項目", "市值"))
                            .foregroundStyle(by: .value("項目", "市值"))
                        PointMark(x: .value("月份", p.month), y: .value("金額", (p.marketValue as NSDecimalNumber).doubleValue))
                            .foregroundStyle(p.estimated ? Color.gray : Color.accentColor)
                        LineMark(x: .value("月份", p.month), y: .value("金額", (p.investedCurrent as NSDecimalNumber).doubleValue),
                                 series: .value("項目", "累計投入"))
                            .foregroundStyle(by: .value("項目", "累計投入"))
                            .interpolationMethod(.stepEnd)
                    }
                }
                .chartXSelection(value: $selected)
                .frame(height: 200)
                if let s = selected, let p = pts.first(where: { $0.month == s }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.month)：市值 \(Fmt.money(p.marketValue, model.viewCurrency))，損益 \(Fmt.signedMoney(p.pnlExDiv, model.viewCurrency))")
                        if p.estimated {
                            Text("推估：\(p.estimatedItems.joined(separator: "、"))\(p.missingFx.isEmpty ? "" : "；缺匯率 \(p.missingFx.joined(separator: "、"))")")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                Text("灰色點表示當月使用推估價格或匯率。").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct FxCard: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: String?

    var body: some View {
        let _ = model.revision
        ForEach(["USD", "JPY"], id: \.self) { ccy in
            let (rate, src) = model.book.currentFx(ccy)
            Button { editing = ccy } label: {
                HStack {
                    Text("\(ccy)/TWD")
                    Spacer()
                    Text(rate.map { Fmt.number($0, digits: ccy == "JPY" ? 4 : 3) } ?? "未設定").monospacedDigit()
                    if src == .manual { Tag(text: "手動") }
                }
            }
            .foregroundStyle(.primary)
        }
        NavigationLink("換算方式說明") { FxExplainView() }
        .sheet(item: Binding(get: { editing.map(IdentifiedString.init) }, set: { editing = $0?.value })) { item in
            ManualValueSheet(kind: .fx(item.value))
        }
    }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.2)))
    }
}

struct FxExplainView: View {
    var body: some View {
        List {
            Section("換算方式") {
                Text("台幣檢視：原幣金額 × 原幣兌台幣匯率")
                Text("美元檢視：原幣金額 × 原幣兌台幣匯率 ÷ 美元兌台幣匯率")
                Text("成本與投入以目前匯率重新估算（docs/02 §2.2）")
                Text("範例：AAPL 10 股 × 190 USD × 32.10 = NT$60,990")
            }
            Section("匯率來源") {
                Text("目前尚未接上自動匯率來源（臺灣銀行與央行的自動取得方式與授權仍在查核）。請在首頁匯率卡手動輸入。")
                Text("手動匯率會一直沿用，直到你再次修改或改回自動。")
            }
        }
        .navigationTitle("換算方式")
    }
}

struct AllocationView: View {
    @EnvironmentObject var model: AppModel
    let ov: Overview

    var body: some View {
        let groups = Dictionary(grouping: ov.rows.filter { $0.marketValueView != nil }) { row in
            model.book.data.instruments.first { $0.id.uuidString == row.instrumentId }.map { marketName($0.market) } ?? "其他"
        }
        let total = ov.totalAssets
        ForEach(groups.keys.sorted(), id: \.self) { k in
            let v = groups[k]!.compactMap(\.marketValueView).reduce(0, +)
            HStack {
                Text(k)
                Spacer()
                Text(Fmt.money(v, model.viewCurrency)).monospacedDigit()
                Text(total > 0 ? Fmt.number(v / total * 100, digits: 1) + "%" : "—").foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            }
        }
    }

    private func marketName(_ m: String) -> String {
        switch m {
        case Market.tw: return "台股／台灣 ETF"
        case Market.us: return "美股／美國 ETF"
        case Market.jp: return "日股／日本 ETF"
        case Market.fundTW: return "基金"
        default: return m
        }
    }
}

struct PortfolioSummaryRows: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ForEach(model.book.activePortfolios) { p in
            NavigationLink { PortfolioDetailView(portfolioId: p.id) } label: {
                HStack {
                    Circle().fill(Color(hex: p.colorHex)).frame(width: 10, height: 10)
                    Text(p.name)
                    if !p.includeInOverview { Text("未納入總覽").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct HoldingsRows: View {
    @EnvironmentObject var model: AppModel
    let ov: Overview

    var body: some View {
        ForEach(ov.rows.filter { $0.quantity != 0 }, id: \.instrumentId) { r in
            let inst = model.book.data.instruments.first { $0.id.uuidString == r.instrumentId }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(inst.map { "\($0.symbol) \($0.name)" } ?? "?").lineLimit(1)
                    Spacer()
                    Text(Fmt.money(r.marketValue, r.currency)).monospacedDigit()
                }
                HStack(spacing: 8) {
                    Text("數量 \(Fmt.quantity(r.quantity))")
                    Text("均價 \(Fmt.number(r.avgCost, digits: 2))")
                    Text("現價 \(Fmt.number(r.price, digits: 2))")
                    if r.priceSource == .manual { Tag(text: "手動") }
                    if r.priceSource == .lastTrade || r.priceSource == .cost { Tag(text: "估計") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DataStatusRow: View {
    @EnvironmentObject var model: AppModel
    let ov: Overview
    let broken: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最後更新：\(Fmt.dateTime(model.book.data.lastRefresh[RefreshCoordinator.twKey]))")
            if let latest = model.book.data.priceCache.values.map(\.dataDate).max() {
                Text("行情資料日：\(Fmt.shortDate(latest))（官方收盤資料可能延遲 1 個交易日以上）")
            }
            if !ov.estimatedInstruments.isEmpty { Text("\(ov.estimatedInstruments.count) 檔使用估計價格") }
            if !ov.missingFx.isEmpty { Text("缺少匯率：\(ov.missingFx.joined(separator: "、"))，相關資產未計入").foregroundStyle(.orange) }
            if !broken.isEmpty { Text("交易資料異常：\(broken.joined(separator: "、"))").foregroundStyle(.red) }
            if let r = model.lastReport, !r.errors.isEmpty {
                Text("更新失敗：\(r.errors.joined(separator: "；"))").foregroundStyle(.orange)
            }
            if let attr = Set(model.book.data.priceCache.values.map(\.attribution)).sorted().first {
                Text(attr)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0x3B82F6
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
