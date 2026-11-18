import DCACore
import DCAKit
import SwiftUI

/// 新增或編輯交易：買入、賣出、股利、費用、分割調整（docs/03 §3.4、§3.5）。
struct TransactionEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let portfolioId: UUID
    let existing: TransactionRecord?

    @State private var type: TxType = .buy
    @State private var instrument: Instrument?
    @State private var picking = false
    @State private var date = Date()
    @State private var price = ""
    @State private var quantity = ""
    @State private var gross = ""
    @State private var fee = ""
    @State private var tax = ""
    @State private var other = ""
    @State private var feeInTWD = false
    @State private var fxRate = ""
    @State private var note = ""

    private var needsQuantity: Bool { [.buy, .sell, .dividendReinvest, .dividendStock, .splitAdjust].contains(type) }
    private var needsPrice: Bool { [.buy, .sell, .dividendReinvest].contains(type) }
    private var needsGross: Bool { [.dividendCash, .dividendReinvest, .fee].contains(type) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("類型", selection: $type) {
                        ForEach([TxType.buy, .sell, .dividendCash, .dividendReinvest, .dividendStock, .fee, .splitAdjust], id: \.self) {
                            Text(TxText.name($0.rawValue)).tag($0)
                        }
                    }
                    Button { picking = true } label: {
                        Text(instrument.map { "\($0.symbol) \($0.name)（\($0.currency)）" } ?? "選擇標的")
                    }
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                }
                Section {
                    if needsPrice { DecimalField(title: type == .dividendReinvest ? "再投入價格" : "價格／淨值", text: $price) }
                    if needsQuantity {
                        DecimalField(title: type == .splitAdjust ? "分割比例（1 拆 4 填 4）" :
                                        type == .dividendStock ? "配發股數" : "數量", text: $quantity)
                    }
                    if needsGross {
                        DecimalField(title: type == .fee ? "費用金額" : "股利總額（扣稅前）", text: $gross)
                    } else if needsPrice, let p = Fmt.decimal(price), let q = Fmt.decimal(quantity) {
                        LabeledContent("成交金額", value: Fmt.number(p * q))
                    }
                }
                if type != .splitAdjust && type != .dividendStock {
                    Section("費用與稅") {
                        DecimalField(title: type == .dividendCash || type == .dividendReinvest ? "匯費" : "手續費", text: $fee)
                        DecimalField(title: type == .dividendCash || type == .dividendReinvest ? "預扣稅" : "交易稅", text: $tax)
                        DecimalField(title: type == .dividendCash ? "二代健保／其他" : "其他費用", text: $other)
                        if let inst = instrument, inst.currency != "TWD" {
                            Toggle("費用以台幣收取（複委託）", isOn: $feeInTWD)
                            if feeInTWD { DecimalField(title: "交易日匯率（1 \(inst.currency) = ? TWD）", text: $fxRate) }
                        }
                    }
                }
                Section { TextField("備註", text: $note) }
                if let existing {
                    Section {
                        Button("刪除這筆紀錄", role: .destructive) {
                            if model.mutate({ try $0.deleteTransaction(existing.id) }) != nil { dismiss() }
                        }
                    } footer: {
                        if existing.occurrenceId != nil { Text("這筆來自定期定額確認；刪除後該期會回到「待確認」。") }
                    }
                }
            }
            .navigationTitle(existing == nil ? "新增紀錄" : "編輯紀錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { save() }.disabled(instrument == nil) }
            }
            .sheet(isPresented: $picking) { InstrumentPickerView { instrument = $0 } }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let t = existing else { return }
        type = TxType(rawValue: t.type) ?? .buy
        instrument = model.book.instrument(t.instrumentId)
        date = LocalDate(iso: t.tradeDate)?.date ?? Date()
        price = t.price?.description ?? ""
        quantity = t.quantity?.description ?? ""
        gross = t.grossAmount.description
        fee = t.fee.description
        tax = t.tax.description
        other = t.otherCost.description
        feeInTWD = t.costCurrency == "TWD" && t.currency != "TWD"
        fxRate = t.fxRateAtTrade?.description ?? ""
        note = t.note ?? ""
    }

    private func save() {
        guard let inst = instrument else { return }
        let p = Fmt.decimal(price), q = Fmt.decimal(quantity)
        var grossValue = Fmt.decimal(gross) ?? 0
        if !needsGross, let p, let q { grossValue = p * q }
        if needsQuantity && q == nil { model.errorMessage = "請輸入數量"; return }
        if needsPrice && p == nil { model.errorMessage = "請輸入價格"; return }
        var tx = TransactionRecord(id: existing?.id ?? UUID(), portfolioId: portfolioId, instrumentId: inst.id, type: type,
                                   tradeDate: LocalDate(date: date).iso,
                                   price: needsPrice ? p.map { Dec($0) } : nil,
                                   quantity: needsQuantity ? q.map { Dec($0) } : nil,
                                   grossAmount: Dec(grossValue),
                                   fee: Dec(Fmt.decimal(fee) ?? 0), tax: Dec(Fmt.decimal(tax) ?? 0),
                                   otherCost: Dec(Fmt.decimal(other) ?? 0),
                                   costCurrency: feeInTWD ? "TWD" : nil, currency: inst.currency,
                                   fxRateAtTrade: feeInTWD ? Fmt.decimal(fxRate).map { Dec($0) } : nil,
                                   occurrenceId: existing?.occurrenceId, note: note.isEmpty ? nil : note)
        if let e = existing { tx.createdAt = e.createdAt }
        let ok: Void?
        if existing == nil {
            ok = model.mutate { _ = try $0.addTransaction(tx) }
        } else {
            ok = model.mutate { try $0.updateTransaction(tx) }
        }
        if ok != nil { dismiss() }
    }
}
