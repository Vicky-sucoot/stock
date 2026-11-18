import DCACore
import DCAKit
import SwiftUI

/// 待確認清單（docs/02 §3.3）：確認、略過，或保留（延後）。
struct PendingListView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirming: OccurrenceRecord?

    var body: some View {
        let _ = model.revision
        let book = model.book
        List {
            ForEach(book.pendingOccurrences) { o in
                let plan = book.data.plans.first { $0.id == o.planId }
                let inst = plan.flatMap { book.instrument($0.instrumentId) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Fmt.shortDate(o.scheduledDate)).bold().monospacedDigit()
                        Text(inst.map { "\($0.symbol) \($0.name)" } ?? "?").lineLimit(1)
                        Spacer()
                        Text(Fmt.money(o.estAmount?.value, plan?.currency ?? "TWD")).monospacedDigit()
                    }
                    if !o.mergedKeys.isEmpty { Text("含 \(o.mergedKeys.count + 1) 期（同一天）").font(.caption) }
                    if !o.adjustReasons.isEmpty {
                        Text(o.adjustReasons.map(Fmt.reason).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                    }
                    if o.calendarUnknown {
                        Text("交易日曆未更新：只排除週末，國定假日請自行確認").font(.caption2).foregroundStyle(.orange)
                    }
                    Text("估計 \(Fmt.quantity(o.estQuantity?.value)) 單位 × \(Fmt.number(o.estPrice?.value)) — 以實際成交為準")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("略過") { model.mutate { try $0.skip(o.id) } }.tint(.gray)
                    Button("確認") { confirming = o }.tint(.blue)
                }
                .onTapGesture { confirming = o }
            }
        }
        .overlay { if book.pendingOccurrences.isEmpty { ContentUnavailableView("沒有待確認的期數", systemImage: "checkmark.circle") } }
        .navigationTitle("待確認")
        .sheet(item: $confirming) { o in ConfirmOccurrenceView(occurrence: o) }
    }
}

struct ConfirmOccurrenceView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let occurrence: OccurrenceRecord

    @State private var tradeDate = Date()
    @State private var price = ""
    @State private var quantity = ""
    @State private var fee = ""
    @State private var tax = ""
    @State private var other = ""
    @State private var feeInTWD = false
    @State private var fxRate = ""

    var body: some View {
        let plan = model.book.data.plans.first { $0.id == occurrence.planId }
        let inst = plan.flatMap { model.book.instrument($0.instrumentId) }
        NavigationStack {
            Form {
                Section(inst.map { "\($0.symbol) \($0.name)" } ?? "") {
                    DatePicker("成交日", selection: $tradeDate, displayedComponents: .date)
                    DecimalField(title: "成交價格\(inst?.assetType == "FUND" ? "（淨值）" : "")", text: $price)
                    DecimalField(title: "數量（股數或單位數）", text: $quantity)
                    if let p = Fmt.decimal(price), let q = Fmt.decimal(quantity) {
                        LabeledContent("成交金額", value: Fmt.money(p * q, inst?.currency ?? "TWD"))
                    }
                }
                Section("費用") {
                    DecimalField(title: "手續費", text: $fee)
                    DecimalField(title: "交易稅", text: $tax)
                    DecimalField(title: "其他費用", text: $other)
                    if inst?.currency != "TWD" {
                        Toggle("費用以台幣收取（複委託）", isOn: $feeInTWD)
                        if feeInTWD { DecimalField(title: "交易日匯率（1 \(inst?.currency ?? "") = ? TWD）", text: $fxRate) }
                    }
                }
            }
            .navigationTitle("確認成交")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("確認") { save() }.disabled(Fmt.decimal(price) == nil || Fmt.decimal(quantity) == nil)
                }
            }
            .onAppear {
                tradeDate = LocalDate(iso: occurrence.scheduledDate)?.date ?? Date()
                price = occurrence.estPrice.map(\.description) ?? ""
                if let q = occurrence.estQuantity?.value {
                    var r = Decimal()
                    var v = q
                    NSDecimalRound(&r, &v, 6, .down)
                    quantity = "\(r)"
                }
                if let plan, let p = occurrence.estPrice?.value, let q = occurrence.estQuantity?.value {
                    fee = "\(plan.estimatedFee(for: p * q))"
                }
            }
        }
    }

    private func save() {
        guard let p = Fmt.decimal(price), let q = Fmt.decimal(quantity) else { return }
        let input = ConfirmInput(tradeDate: LocalDate(date: tradeDate).iso, price: p, quantity: q,
                                 fee: Fmt.decimal(fee) ?? 0, tax: Fmt.decimal(tax) ?? 0, otherCost: Fmt.decimal(other) ?? 0,
                                 costCurrency: feeInTWD ? "TWD" : nil, fxRateAtTrade: feeInTWD ? Fmt.decimal(fxRate) : nil)
        if model.mutate({ try $0.confirm(occurrence.id, input) }) != nil { dismiss() }
    }
}

/// 十進位輸入欄（數字鍵盤，不使用浮點數）。
struct DecimalField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 160)
                .foregroundStyle(text.isEmpty || Fmt.decimal(text) != nil ? Color.primary : Color.red)
        }
    }
}
