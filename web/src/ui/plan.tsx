import { useMemo, useState } from "react";
import { parseDecimal, PortfolioBook, type Instrument, type PlanRecord } from "../app/book";
import { D, Decimal } from "../core/decimal";
import { DecimalInput, Field, Page, Row, Section, Segmented } from "./components";
import { localToday, money, num, qty, REASON, shortDate } from "./fmt";
import { useApp } from "./model";
import { back, go } from "./router";
import { InstrumentPicker } from "./picker";

export function PlanEdit({ portfolioId, id }: { portfolioId: string; id: string }) {
  const { book, run } = useApp();
  const existing = id === "new" ? undefined : book!.data.plans.find((p) => p.id === id);
  const [inst, setInst] = useState<Instrument | undefined>(existing ? book!.instrument(existing.instrumentId) : undefined);
  const [picking, setPicking] = useState(false);
  const [mode, setMode] = useState<"AMOUNT" | "QUANTITY">(existing?.amountMode ?? "AMOUNT");
  const [amount, setAmount] = useState(existing?.amount ?? "");
  const [freq, setFreq] = useState<"WEEKLY" | "MONTHLY" | "DATES">(existing?.frequency ?? "MONTHLY");
  const [weekdays, setWeekdays] = useState<number[]>(existing?.weekdays ?? [1]);
  const [monthDays, setMonthDays] = useState(existing?.monthDays.join(",") ?? "6");
  const [dates, setDates] = useState<string[]>(existing?.specificDates ?? []);
  const [newDate, setNewDate] = useState(localToday());
  const [rule, setRule] = useState<"NEXT_TRADING_DAY" | "PREV_TRADING_DAY">(existing?.holidayRule ?? "NEXT_TRADING_DAY");
  const [start, setStart] = useState(existing?.startDate ?? localToday());
  const [end, setEnd] = useState(existing?.endDate ?? "");
  const [feeMode, setFeeMode] = useState<"FIXED" | "RATE">(existing?.feeMode ?? "FIXED");
  const [feeValue, setFeeValue] = useState(existing?.feeValue ?? "0");
  const [feeMin, setFeeMin] = useState(existing?.feeMin ?? "0");
  const [paused, setPaused] = useState(existing?.paused ?? false);
  const [askCatchUp, setAskCatchUp] = useState(false);

  const draft: PlanRecord | null = useMemo(() => {
    const amt = parseDecimal(amount);
    if (!inst || !amt?.gt(0)) return null;
    const p: PlanRecord = {
      id: existing?.id ?? "draft", portfolioId, instrumentId: inst.id, amountMode: mode, amount: amt.toString(), currency: inst.currency,
      frequency: freq, weekdays: freq === "WEEKLY" ? [...weekdays].sort() : [],
      monthDays: freq === "MONTHLY" ? monthDays.split(/[,，\s]+/).map(Number).filter((n) => Number.isInteger(n) && n > 0) : [],
      specificDates: freq === "DATES" ? [...dates].sort() : [], holidayRule: rule, startDate: start, endDate: end || null,
      generateFrom: existing?.generateFrom ?? start, feeMode, feeValue: parseDecimal(feeValue)?.toString() ?? "0",
      feeMin: parseDecimal(feeMin)?.toString() ?? "0", paused, note: existing?.note,
    };
    try {
      PortfolioBook.corePlan(p);
      return p;
    } catch {
      return null;
    }
  }, [inst, amount, mode, freq, weekdays, monthDays, dates, rule, start, end, feeMode, feeValue, feeMin, paused, existing, portfolioId]);

  const preview = useMemo(() => (draft ? book!.previewUpcoming(draft) : []), [draft, book]);

  const create = async (catchUp: boolean) => {
    if (!draft) return;
    const { id: _ignored, generateFrom: _g, ...rest } = draft;
    void _ignored;
    void _g;
    const ok = await run(async (b) => {
      const r = await b.createPlan(rest, catchUp);
      await b.generatePending();
      return r;
    });
    if (ok !== undefined) back();
  };
  const save = async () => {
    if (!draft) return;
    if (existing) {
      if ((await run((b) => b.updatePlan(draft))) !== undefined) back();
    } else if (start < book!.today(inst?.market)) setAskCatchUp(true);
    else await create(false);
  };

  if (picking) return <Page title="選擇標的" onBack><InstrumentPicker onPick={(i) => { setInst(i); setPicking(false); }} onCancel={() => setPicking(false)} /></Page>;
  return (
    <Page title={existing ? "編輯定期定額" : "新增定期定額"} onBack action={<button className="link" disabled={!draft} onClick={save}>儲存</button>}>
      <Section title="標的">
        <Row onClick={existing ? undefined : () => setPicking(true)} label={inst ? `${inst.symbol} ${inst.name}（${inst.currency}）` : "選擇標的"} value={existing ? "" : "›"} />
      </Section>
      <Section title="每期">
        <Segmented label="方式" value={mode} onChange={setMode} options={[["AMOUNT", "固定金額"], ["QUANTITY", "固定數量"]]} />
        <DecimalInput label={mode === "AMOUNT" ? `金額（${inst?.currency ?? ""}）` : "數量"} value={amount} onChange={setAmount} />
      </Section>
      <Section title="頻率">
        <Segmented label="頻率" value={freq} onChange={setFreq} options={[["WEEKLY", "每週"], ["MONTHLY", "每月"], ["DATES", "指定日期"]]} />
        {freq === "WEEKLY" && (
          <div className="weekdays">{[1, 2, 3, 4, 5].map((d) => (
            <label key={d} className="check"><input type="checkbox" checked={weekdays.includes(d)} onChange={(e) => setWeekdays(e.target.checked ? [...weekdays, d] : weekdays.filter((x) => x !== d))} /><span>週{"一二三四五"[d - 1]}</span></label>
          ))}</div>
        )}
        {freq === "MONTHLY" && (
          <Field label="每月幾號（可多個，以逗號分隔，例如 6,16,26）"><input inputMode="numeric" value={monthDays} onChange={(e) => setMonthDays(e.target.value)} aria-label="每月日期" /></Field>
        )}
        {freq === "MONTHLY" && <p className="foot">若當月沒有該日（例如 31 日），改為當月最後一天。</p>}
        {freq === "DATES" && (
          <>
            {dates.map((d) => <Row key={d} label={shortDate(d)} value={<button className="link" onClick={() => setDates(dates.filter((x) => x !== d))}>移除</button>} />)}
            <div className="inline"><input type="date" value={newDate} onChange={(e) => setNewDate(e.target.value)} aria-label="新增日期" /><button className="link" onClick={() => newDate && !dates.includes(newDate) && setDates([...dates, newDate])}>加入</button></div>
          </>
        )}
        <Segmented label="遇休市" value={rule} onChange={setRule} options={[["NEXT_TRADING_DAY", "順延至下一交易日"], ["PREV_TRADING_DAY", "提前至前一交易日"]]} />
      </Section>
      <Section title="期間">
        <Field label="開始日"><input type="date" value={start} onChange={(e) => setStart(e.target.value)} aria-label="開始日" /></Field>
        <Field label="結束日（選填）"><input type="date" value={end} onChange={(e) => setEnd(e.target.value)} aria-label="結束日" /></Field>
        <label className="check"><input type="checkbox" checked={paused} onChange={(e) => setPaused(e.target.checked)} /><span>暫停</span></label>
      </Section>
      <Section title="預設手續費（確認時可修改）">
        <Segmented label="手續費方式" value={feeMode} onChange={setFeeMode} options={[["FIXED", "固定金額"], ["RATE", "費率"]]} />
        <DecimalInput label={feeMode === "FIXED" ? "手續費金額" : "手續費率（例如 0.001425）"} value={feeValue} onChange={setFeeValue} />
        {feeMode === "RATE" && <DecimalInput label="最低收費" value={feeMin} onChange={setFeeMin} />}
      </Section>
      {preview.length > 0 && (
        <Section title="接下來 6 期" footer={preview.some((o) => o.calendarUnknown) ? "尚未匯入休市表：目前只排除週末，國定假日請自行確認。" : undefined}>
          {preview.map((o) => <Row key={o.periodKey} label={shortDate(o.scheduledDate)} value={o.adjustReasons.map((r) => REASON[r] ?? r).join("、")} />)}
        </Section>
      )}
      {askCatchUp && (
        <Section title="開始日早於今天">
          <p>要補產生過去的待確認期數嗎？</p>
          <button className="primary" onClick={() => create(true)}>補產生</button>
          <button className="link" onClick={() => create(false)}>只從今天開始</button>
        </Section>
      )}
      {existing && (
        <Section footer="已確認的交易紀錄會保留；尚未確認的期數會移除。">
          <button className="link danger" onClick={async () => { if ((await run((b) => b.deletePlan(existing.id))) !== undefined) back(); }}>刪除計畫</button>
        </Section>
      )}
    </Page>
  );
}

export function PendingList() {
  const { book, rev, run } = useApp();
  void rev;
  const pend = book!.pendingOccurrences;
  return (
    <Page title="待確認" onBack>
      <Section footer="App 不會扣款；請依實際成交補上價格、數量與費用。略過代表該期沒有扣款。">
        {pend.length === 0 && <p className="muted">沒有待確認的期數</p>}
        {pend.map((o) => {
          const plan = book!.data.plans.find((p) => p.id === o.planId);
          const inst = plan && book!.instrument(plan.instrumentId);
          return (
            <div key={o.id} className="pending">
              <Row onClick={() => go("confirm", o.id)} label={`${shortDate(o.scheduledDate)} ${inst ? `${inst.symbol} ${inst.name}` : "?"}`}
                value={o.estAmount ? money(D(o.estAmount), plan!.currency) : "—"}
                sub={<>
                  {o.mergedKeys.length > 0 && <>含 {o.mergedKeys.length + 1} 期（同一天）・</>}
                  {o.adjustReasons.filter((r) => r !== "MERGED").map((r) => REASON[r] ?? r).join("、")}
                  {o.calendarUnknown && <span className="warn">　交易日曆未更新：國定假日請自行確認</span>}
                  <br />估計 {o.estQuantity ? qty(D(o.estQuantity)) : "—"} 單位 × {o.estPrice ? num(D(o.estPrice)) : "—"}（以實際成交為準）
                </>} />
              <div className="actions">
                <button className="primary small" onClick={() => go("confirm", o.id)}>確認</button>
                <button className="small" onClick={() => run((b) => b.skip(o.id))}>略過</button>
              </div>
            </div>
          );
        })}
      </Section>
    </Page>
  );
}

export function ConfirmOccurrence({ id }: { id: string }) {
  const { book, run } = useApp();
  const o = book!.data.occurrences.find((x) => x.id === id);
  const plan = o && book!.data.plans.find((p) => p.id === o.planId);
  const inst = plan && book!.instrument(plan.instrumentId);
  const [date, setDate] = useState(o?.scheduledDate ?? localToday());
  const [price, setPrice] = useState(o?.estPrice ?? "");
  const [quantity, setQuantity] = useState(o?.estQuantity ? D(o.estQuantity).toDecimalPlaces(6, 1).toString() : "");
  const [fee, setFee] = useState(() => {
    if (!plan || !o?.estPrice || !o.estQuantity) return "0";
    const gross = D(o.estPrice).times(o.estQuantity);
    return (plan.feeMode === "FIXED" ? D(plan.feeValue) : Decimal.max(D(plan.feeMin), gross.times(plan.feeValue))).toDecimalPlaces(2).toString();
  });
  const [tax, setTax] = useState("0");
  const [other, setOther] = useState("0");
  const [twdFee, setTwdFee] = useState(false);
  const [rate, setRate] = useState("");
  if (!o || !plan || !inst) return <Page title="找不到期別" onBack><p className="muted">這一期不存在。</p></Page>;
  const p = parseDecimal(price), q = parseDecimal(quantity);
  return (
    <Page title="確認成交" onBack action={<button className="link" disabled={!p || !q} onClick={async () => {
      const ok = await run((b) => b.confirm(o.id, { tradeDate: date, price, quantity, fee, tax, otherCost: other, costCurrency: twdFee ? "TWD" : null, fxRateAtTrade: twdFee ? rate : null }));
      if (ok !== undefined) back();
    }}>確認</button>}>
      <Section title={`${inst.symbol} ${inst.name}`}>
        <Field label="成交日"><input type="date" value={date} onChange={(e) => setDate(e.target.value)} aria-label="成交日" /></Field>
        <DecimalInput label={inst.assetType === "FUND" ? "淨值" : "成交價格"} value={price} onChange={setPrice} />
        <DecimalInput label="數量（股數或單位數）" value={quantity} onChange={setQuantity} />
        {p && q && <Row label="成交金額" value={money(p.times(q), inst.currency)} />}
      </Section>
      <Section title="費用">
        <DecimalInput label="手續費" value={fee} onChange={setFee} />
        <DecimalInput label="交易稅" value={tax} onChange={setTax} />
        <DecimalInput label="其他費用" value={other} onChange={setOther} />
        {inst.currency !== "TWD" && <label className="check"><input type="checkbox" checked={twdFee} onChange={(e) => setTwdFee(e.target.checked)} /><span>費用以台幣收取（複委託）</span></label>}
        {twdFee && <DecimalInput label={`交易日匯率（1 ${inst.currency} = ? TWD）`} value={rate} onChange={setRate} />}
      </Section>
    </Page>
  );
}
