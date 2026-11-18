import { useState } from "react";
import { parseDecimal, type Instrument } from "../app/book";
import { D } from "../core/decimal";
import type { TxType } from "../core/ledger";
import { DecimalInput, Field, Page, Row, Section, Tag } from "./components";
import { localToday, money, num, shortDate, TX_NAME } from "./fmt";
import { useApp } from "./model";
import { back, go } from "./router";
import { InstrumentPicker } from "./picker";

const TYPES: TxType[] = ["BUY", "SELL", "DIVIDEND_CASH", "DIVIDEND_REINVEST", "DIVIDEND_STOCK", "FEE", "SPLIT_ADJUST"];

export function TxEdit({ portfolioId, id }: { portfolioId: string; id?: string }) {
  const { book, run, setError } = useApp();
  const ex = id ? book!.data.transactions.find((t) => t.id === id) : undefined;
  const [type, setType] = useState<TxType>(ex?.type ?? "BUY");
  const [inst, setInst] = useState<Instrument | undefined>(ex ? book!.instrument(ex.instrumentId) : undefined);
  const [picking, setPicking] = useState(false);
  const [date, setDate] = useState(ex?.tradeDate ?? localToday());
  const [price, setPrice] = useState(ex?.price ?? "");
  const [quantity, setQuantity] = useState(ex?.quantity ?? "");
  const [gross, setGross] = useState(ex?.grossAmount ?? "");
  const [fee, setFee] = useState(ex?.fee ?? "0");
  const [tax, setTax] = useState(ex?.tax ?? "0");
  const [other, setOther] = useState(ex?.otherCost ?? "0");
  const [twdFee, setTwdFee] = useState(!!ex?.costCurrency && ex.costCurrency !== ex.currency);
  const [rate, setRate] = useState(ex?.fxRateAtTrade ?? "");
  const [note, setNote] = useState(ex?.note ?? "");
  const needsQty = ["BUY", "SELL", "DIVIDEND_REINVEST", "DIVIDEND_STOCK", "SPLIT_ADJUST"].includes(type);
  const needsPrice = ["BUY", "SELL", "DIVIDEND_REINVEST"].includes(type);
  const needsGross = ["DIVIDEND_CASH", "DIVIDEND_REINVEST", "FEE"].includes(type);
  const isDiv = type === "DIVIDEND_CASH" || type === "DIVIDEND_REINVEST";

  const save = async () => {
    if (!inst) return;
    const p = parseDecimal(price), q = parseDecimal(quantity);
    if (needsQty && !q) return setError("請輸入數量");
    if (needsPrice && !p) return setError("請輸入價格");
    const g = needsGross ? parseDecimal(gross) ?? D(0) : p && q ? p.times(q) : D(0);
    const rec = {
      portfolioId, instrumentId: inst.id, type, tradeDate: date, price: needsPrice ? p!.toString() : null, quantity: needsQty ? q!.toString() : null,
      grossAmount: g.toString(), fee: parseDecimal(fee)?.toString() ?? "0", tax: parseDecimal(tax)?.toString() ?? "0",
      otherCost: parseDecimal(other)?.toString() ?? "0", costCurrency: twdFee ? "TWD" : null, currency: inst.currency,
      fxRateAtTrade: twdFee ? parseDecimal(rate)?.toString() ?? null : null, occurrenceId: ex?.occurrenceId ?? null, note: note || undefined,
    };
    const ok = ex ? await run((b) => b.updateTransaction({ ...ex, ...rec })) : await run((b) => b.addTransaction(rec));
    if (ok !== undefined) back();
  };

  if (picking) return <Page title="選擇標的" onBack><InstrumentPicker onPick={(i) => { setInst(i); setPicking(false); }} onCancel={() => setPicking(false)} /></Page>;
  return (
    <Page title={ex ? "編輯紀錄" : "新增紀錄"} onBack action={<button className="link" disabled={!inst} onClick={save}>儲存</button>}>
      <Section>
        <Field label="類型">
          <select value={type} onChange={(e) => setType(e.target.value as TxType)} aria-label="類型">
            {TYPES.map((t) => <option key={t} value={t}>{TX_NAME[t]}</option>)}
          </select>
        </Field>
        <Row onClick={() => setPicking(true)} label={inst ? `${inst.symbol} ${inst.name}（${inst.currency}）` : "選擇標的"} value="›" />
        <Field label="日期"><input type="date" value={date} onChange={(e) => setDate(e.target.value)} aria-label="日期" /></Field>
      </Section>
      <Section>
        {needsPrice && <DecimalInput label={type === "DIVIDEND_REINVEST" ? "再投入價格" : "價格／淨值"} value={price} onChange={setPrice} />}
        {needsQty && <DecimalInput label={type === "SPLIT_ADJUST" ? "分割比例（1 拆 4 填 4）" : type === "DIVIDEND_STOCK" ? "配發股數" : "數量"} value={quantity} onChange={setQuantity} />}
        {needsGross && <DecimalInput label={type === "FEE" ? "費用金額" : "股利總額（扣稅前）"} value={gross} onChange={setGross} />}
        {!needsGross && needsPrice && parseDecimal(price) && parseDecimal(quantity) && <Row label="成交金額" value={num(parseDecimal(price)!.times(parseDecimal(quantity)!))} />}
      </Section>
      {type !== "SPLIT_ADJUST" && type !== "DIVIDEND_STOCK" && (
        <Section title="費用與稅">
          <DecimalInput label={isDiv ? "匯費" : "手續費"} value={fee} onChange={setFee} />
          <DecimalInput label={isDiv ? "預扣稅" : "交易稅"} value={tax} onChange={setTax} />
          <DecimalInput label={type === "DIVIDEND_CASH" ? "二代健保／其他" : "其他費用"} value={other} onChange={setOther} />
          {inst && inst.currency !== "TWD" && <label className="check"><input type="checkbox" checked={twdFee} onChange={(e) => setTwdFee(e.target.checked)} /><span>費用以台幣收取（複委託）</span></label>}
          {twdFee && <DecimalInput label={`交易日匯率（1 ${inst?.currency} = ? TWD）`} value={rate} onChange={setRate} />}
        </Section>
      )}
      <Section><Field label="備註"><input value={note} onChange={(e) => setNote(e.target.value)} aria-label="備註" /></Field></Section>
      {ex && (
        <Section footer={ex.occurrenceId ? "這筆來自定期定額確認；刪除後該期會回到「待確認」。" : undefined}>
          <button className="link danger" onClick={async () => { if ((await run((b) => b.deleteTransaction(ex.id))) !== undefined) back(); }}>刪除這筆紀錄</button>
        </Section>
      )}
    </Page>
  );
}

export function InstrumentDetail({ portfolioId, id }: { portfolioId: string; id: string }) {
  const { book, rev, run } = useApp();
  void rev;
  const inst = book!.instrument(id);
  if (!inst) return <Page title="找不到標的" onBack><p className="muted">這個標的不存在。</p></Page>;
  const [price, src] = book!.currentPrice(inst);
  const cache = book!.data.priceCache[inst.id];
  return (
    <Page title={`${inst.symbol} ${inst.name}`} onBack>
      <Section title="價格">
        <Row label="目前採用" value={<>{num(price)} {src === "MANUAL" && <Tag text="手動" />}</>} />
        {cache && <Row label="自動參考值" value={`${num(D(cache.value))}（資料日 ${shortDate(cache.dataDate)}）`} sub={cache.attribution} />}
        <button className="link" onClick={() => go("manual", "price", inst.id)}>手動設定價格{inst.assetType === "FUND" ? "／淨值" : ""}</button>
        {src === "MANUAL" && <button className="link" onClick={() => run((b) => b.revertToAuto(inst.id))}>改回自動</button>}
      </Section>
      <Section title="交易紀錄">
        {book!.transactions(portfolioId, id).map((t) => (
          <Row key={t.id} onClick={() => go("tx", portfolioId, t.id)} label={`${shortDate(t.tradeDate)} ${TX_NAME[t.type]}`} value={money(D(t.grossAmount), t.currency)} />
        ))}
      </Section>
    </Page>
  );
}
