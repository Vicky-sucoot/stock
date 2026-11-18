import DCACore
import DCAKit
import SwiftUI

/// 定期定額計畫編輯（docs/03 §3.3），底部即時預覽接下來 6 期。
struct PlanEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let portfolioId: UUID
    let existing: PlanRecord?

    @State private var instrument: Instrument?
    @State private var picking = false
    @State private var amountMode: AmountMode = .amount
    @State private var amount = ""
    @State private var frequency = "MONTHLY"
    @State private var weekdays: Set<Int> = [1]
    @State private var monthDaysText = "6"
    @State private var specificDates: [Date] = []
    @State private var newDate = Date()
    @State private var holidayRule = HolidayRule.nextTradingDay.rawValue
    @State private var startDate = Date()
    @State private var hasEnd = false
    @State private var endDate = Date()
    @State private var feeMode: FeeMode = .fixed
    @State private var feeValue = ""
    @State private var feeMin = ""
    @State private var paused = false
    @State private var askCatchUp = false

    var body: some View {
        NavigationStack {
            Form {
                Section("標的") {
                    Button { picking = true } label: {
                        Text(instrument.map { "\($0.symbol) \($0.name)（\($0.currency)）" } ?? "選擇標的")
                    }
                    .disabled(existing != nil)
                }
                Section("每期") {
                    Picker("方式", selection: $amountMode) {
                        Text("固定金額").tag(AmountMode.amount)
                        Text("固定數量").tag(AmountMode.quantity)
                    }
                    .pickerStyle(.segmented)
                    DecimalField(title: amountMode == .amount ? "金額（\(instrument?.currency ?? "")）" : "數量", text: $amount)
                }
                Section("頻率") {
                    Picker("頻率", selection: $frequency) {
                        Text("每週").tag("WEEKLY")
                        Text("每月").tag("MONTHLY")
                        Text("指定日期").tag("DATES")
                    }
                    .pickerStyle(.segmented)
                    switch frequency {
                    case "WEEKLY":
                        ForEach(1...5, id: \.self) { d in
                            Toggle("週" + ["", "一", "二", "三", "四", "五"][d], isOn: Binding(
                                get: { weekdays.contains(d) },
                                set: { if $0 { weekdays.insert(d) } else { weekdays.remove(d) } }))
                        }
                    case "MONTHLY":
                        TextField("每月幾號（可多個，以逗號分隔，例如 6,16,26）", text: $monthDaysText)
                            .keyboardType(.numbersAndPunctuation)
                        Text("若當月沒有該日（例如 31 日），改為當月最後一天。").font(.caption).foregroundStyle(.secondary)
                    default:
                        ForEach(specificDates, id: \.self) { d in Text(LocalDate(date: d).iso) }
                            .onDelete { specificDates.remove(atOffsets: $0) }
                        HStack {
                            DatePicker("新增日期", selection: $newDate, displayedComponents: .date)
                            Button("加入") { specificDates.append(newDate); specificDates.sort() }
                        }
                    }
                    Picker("遇休市", selection: $holidayRule) {
                        Text("順延至下一交易日").tag(HolidayRule.nextTradingDay.rawValue)
                        Text("提前至前一交易日").tag(HolidayRule.prevTradingDay.rawValue)
                    }
                }
                Section("期間") {
                    DatePicker("開始日", selection: $startDate, displayedComponents: .date)
                    Toggle("設定結束日", isOn: $hasEnd)
                    if hasEnd { DatePicker("結束日", selection: $endDate, displayedComponents: .date) }
                    Toggle("暫停", isOn: $paused)
                }
                Section("預設手續費（確認時可修改）") {
                    Picker("方式", selection: $feeMode) {
                        Text("固定金額").tag(FeeMode.fixed)
                        Text("費率").tag(FeeMode.rate)
                    }
                    .pickerStyle(.segmented)
                    DecimalField(title: feeMode == .fixed ? "金額" : "費率（例如 0.001425）", text: $feeValue)
                    if feeMode == .rate { DecimalField(title: "最低收費", text: $feeMin) }
                }
                if let plan = draft(), let preview = try? model.book.previewUpcoming(plan) {
                    Section("接下來 6 期") {
                        ForEach(preview, id: \.periodKey) { o in
                            HStack {
                                Text(o.scheduledDate.iso).monospacedDigit()
                                if !o.adjustReasons.isEmpty {
                                    Text(o.adjustReasons.map(Fmt.reason).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if preview.contains(where: \.calendarUnknown) {
                            Text("尚未匯入休市表：目前只排除週末。").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if let existing {
                    Section {
                        Button("刪除計畫", role: .destructive) {
                            if model.mutate({ try $0.deletePlan(existing.id) }) != nil { dismiss() }
                        }
                    } footer: { Text("已確認的交易紀錄會保留；尚未確認的期數會移除。") }
                }
            }
            .navigationTitle(existing == nil ? "新增定期定額" : "編輯定期定額")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { save() }.disabled(draft() == nil) }
            }
            .sheet(isPresented: $picking) { InstrumentPickerView { instrument = $0 } }
            .confirmationDialog("開始日早於今天，要補產生過去的待確認期數嗎？", isPresented: $askCatchUp, titleVisibility: .visible) {
                Button("補產生") { create(catchUp: true) }
                Button("只從今天開始") { create(catchUp: false) }
                Button("取消", role: .cancel) {}
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let p = existing else { return }
        instrument = model.book.instrument(p.instrumentId)
        amountMode = p.amountMode
        amount = p.amount.description
        frequency = p.frequency
        weekdays = Set(p.weekdays)
        monthDaysText = p.monthDays.map(String.init).joined(separator: ",")
        specificDates = p.specificDates.compactMap { LocalDate(iso: $0)?.date }
        holidayRule = p.holidayRule
        startDate = LocalDate(iso: p.startDate)?.date ?? Date()
        hasEnd = p.endDate != nil
        endDate = p.endDate.flatMap { LocalDate(iso: $0)?.date } ?? Date()
        feeMode = p.feeMode
        feeValue = p.feeValue.description
        feeMin = p.feeMin.description
        paused = p.paused
    }

    private func draft() -> PlanRecord? {
        guard let inst = instrument, let amt = Fmt.decimal(amount), amt > 0 else { return nil }
        let days = monthDaysText.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " }).compactMap { Int($0) }
        var p = PlanRecord(id: existing?.id ?? UUID(), portfolioId: portfolioId, instrumentId: inst.id, amountMode: amountMode,
                           amount: Dec(amt), currency: inst.currency, frequency: frequency,
                           weekdays: frequency == "WEEKLY" ? weekdays.sorted() : [],
                           monthDays: frequency == "MONTHLY" ? days : [],
                           specificDates: frequency == "DATES" ? specificDates.map { LocalDate(date: $0).iso } : [],
                           holidayRule: holidayRule, startDate: LocalDate(date: startDate).iso,
                           endDate: hasEnd ? LocalDate(date: endDate).iso : nil,
                           generateFrom: existing?.generateFrom,
                           feeMode: feeMode, feeValue: Dec(Fmt.decimal(feeValue) ?? 0), feeMin: Dec(Fmt.decimal(feeMin) ?? 0),
                           paused: paused, note: existing?.note)
        p.feeCurrency = existing?.feeCurrency ?? inst.currency
        return (try? p.corePlan()) != nil ? p : nil
    }

    private func save() {
        guard let p = draft() else { return }
        if existing != nil {
            if model.mutate({ try $0.updatePlan(p) }) != nil { dismiss() }
        } else if LocalDate(date: startDate) < model.book.today(market: instrument?.market ?? Market.tw) {
            askCatchUp = true
        } else {
            create(catchUp: false)
        }
    }

    private func create(catchUp: Bool) {
        guard let p = draft() else { return }
        if model.mutate({ book -> PlanRecord in
            let created = try book.createPlan(p, catchUp: catchUp)
            try book.generatePending()
            return created
        }) != nil { dismiss() }
    }
}
