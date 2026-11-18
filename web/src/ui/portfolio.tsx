import { useMemo, useState } from "react";
import type { Portfolio } from "../app/book";
import { PortfolioBook } from "../app/book";
import { D } from "../core/decimal";
import { buildPosition, avgCost } from "../core/ledger";
import { Field, Page, Row, Section, Segmented, Tag } from "./components";
import { money, num, pct, qty, shortDate, TX_NAME } from "./fmt";
import { describeError, useApp } from "./model";
import { back, go } from "./router";

const COLORS = ["#3B82F6", "#EF4444", "#10B981", "#F59E0B", "#8B5CF6", "#6B7280"];

export function PortfolioList() {
  const { book, rev } = useApp();
  const [archived, setArchived] = useState(false);
  void rev;
  const all = [...book!.data.portfolios].sort((a, b) => a.sortOrder - b.sortOrder).filter((p) => archived || !p.archivedAt);
  return (
    <Page title="投資組合" action={<button className="link" onClick={() => go("portfolio-new")}>新增</button>}>
      <Section>
        {all.map((p) => <Row key={p.id} onClick={() => go("portfolio", p.id)} label={<><span className="dot" style={{ background: p.colorHex }} />{p.name}{p.archivedAt && <Tag text="已封存" tone="info" />}</>} value="›" />)}
        <label className="check"><input type="checkbox" checked={archived} onChange={(e) => setArchived(e.target.checked)} /><span>顯示已封存</span></label>
      </Section>
    </Page>
  );
}

export function PortfolioEdit({ id }: { id?: string }) {
  const { book, run } = useApp();
  const existing = id ? book!.data.portfolios.find((p) => p.id === id) : undefined;
  const [name, setName] = useState(existing?.name ?? "");
  const [note, setNote] = useState(existing?.note ?? "");
  const [color, setColor] = useState(existing?.colorHex ?? COLORS[0]);
  const [ccy, setCcy] = useState(existing?.defaultCurrency ?? "TWD");
  const [include, setInclude] = useState(existing?.includeInOverview ?? true);
  const save = async () => {
    const ok = existing
      ? await run((b) => b.updatePortfolio({ ...existing, name, note: note || undefined, colorHex: color, defaultCurrency: ccy, includeInOverview: include }))
      : await run((b) => b.createPortfolio(name, { note: note || undefined, colorHex: color, defaultCurrency: ccy, includeInOverview: include }));
    if (ok !== undefined) back();
  };
  return (
    <Page title={existing ? "編輯投資組合" : "新增投資組合"} onBack action={<button className="link" onClick={save}>儲存</button>}>
      <Section>
        <Field label="名稱（1～20 字）"><input value={name} onChange={(e) => setName(e.target.value)} aria-label="名稱" /></Field>
        <Field label="說明（選填）"><input value={note} onChange={(e) => setNote(e.target.value)} aria-label="說明" /></Field>
        <div className="colors">{COLORS.map((c) => <button key={c} aria-label={`顏色 ${c}`} className={c === color ? "on" : ""} style={{ background: c }} onClick={() => setColor(c)} />)}</div>
        <Segmented label="預設幣別" value={ccy} onChange={setCcy} options={[["TWD", "TWD"], ["USD", "USD"], ["JPY", "JPY"]]} />
        <label className="check"><input type="checkbox" checked={include} onChange={(e) => setInclude(e.target.checked)} /><span>納入首頁合併總覽</span></label>
      </Section>
    </Page>
  );
}

export function PortfolioDetail({ id }: { id: string }) {
  const { book, rev, run, passcode, setError } = useApp();
  const [tab, setTab] = useState<"hold" | "plan" | "tx">("hold");
  const [delPin, setDelPin] = useState<string | null>(null);
  void rev;
  const p: Portfolio | undefined = book!.data.portfolios.find((x) => x.id === id);
  const holdings = useMemo(() => {
    const m = new Map<string, ReturnType<PortfolioBook["transactions"]>>();
    for (const t of book!.transactions(id)) m.set(t.instrumentId, [...(m.get(t.instrumentId) ?? []), t]);
    return [...m.entries()];
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [book, id, rev]);
  if (!p) return <Page title="找不到投資組合" onBack><p className="muted">這個投資組合不存在。</p></Page>;
  return (
    <Page title={p.name} onBack action={<button className="link" onClick={() => go("portfolio-edit", id)}>編輯</button>}>
      <Segmented label="分頁" value={tab} onChange={setTab} options={[["hold", "持有"], ["plan", "計畫"], ["tx", "交易"]]} />
      {tab === "hold" && (
        <Section>
          {holdings.length === 0 && <p className="muted">尚無交易紀錄</p>}
          {holdings.map(([iid, txs]) => {
            const inst = book!.instrument(iid);
            if (!inst) return null;
            let pos;
            try {
              pos = buildPosition(txs.map(PortfolioBook.coreTx));
            } catch {
              return <Row key={iid} label={`${inst.symbol} ${inst.name}`} value="資料異常" />;
            }
            const [price, src] = book!.currentPrice(inst);
            const mv = price ? pos.quantity.times(price) : null;
            const ret = mv && pos.costBasis.gt(0) ? mv.minus(pos.costBasis).div(pos.costBasis) : null;
            return (
              <Row key={iid} onClick={() => go("instrument", id, iid)} label={`${inst.symbol} ${inst.name}`} value={money(mv, inst.currency)}
                sub={<>數量 {qty(pos.quantity)}・均價 {num(avgCost(pos))}・現價 {num(price)} {src === "MANUAL" && <Tag text="手動" />}・{pct(ret)}</>} />
            );
          })}
          <button className="link" onClick={() => go("tx-new", id)}>＋ 新增交易／股利／費用</button>
        </Section>
      )}
      {tab === "plan" && (
        <Section>
          {book!.data.plans.filter((x) => x.portfolioId === id).map((pl) => {
            const inst = book!.instrument(pl.instrumentId);
            const when = pl.frequency === "WEEKLY" ? `每週${pl.weekdays.map((d) => "一二三四五六日"[d - 1]).join("、")}` : pl.frequency === "MONTHLY" ? `每月 ${pl.monthDays.join("、")} 日` : `指定日期 ${pl.specificDates.length} 天`;
            return <Row key={pl.id} onClick={() => go("plan", id, pl.id)} label={inst ? `${inst.symbol} ${inst.name}` : "?"} sub={`${when}・${pl.amountMode === "AMOUNT" ? `${pl.currency} ${pl.amount}` : `${pl.amount} 單位`}${pl.paused ? "・暫停中" : ""}`} value="›" />;
          })}
          <button className="link" onClick={() => go("plan", id, "new")}>＋ 新增定期定額計畫</button>
        </Section>
      )}
      {tab === "tx" && (
        <Section>
          {book!.transactions(id).length === 0 && <p className="muted">尚無交易紀錄</p>}
          {book!.transactions(id).map((t) => (
            <Row key={t.id} onClick={() => go("tx", id, t.id)} label={`${shortDate(t.tradeDate)} ${TX_NAME[t.type]} ${book!.instrument(t.instrumentId)?.symbol ?? ""}`}
              value={money(D(t.grossAmount), t.currency)} />
          ))}
          <button className="link" onClick={() => go("tx-new", id)}>＋ 新增紀錄</button>
        </Section>
      )}
      <Section>
        <button className="link" onClick={() => run((b) => b.setArchived(id, !p.archivedAt))}>{p.archivedAt ? "取消封存" : "封存"}</button>
        {delPin === null ? (
          <button className="link danger" onClick={() => setDelPin("")}>刪除組合</button>
        ) : (
          <>
            <p className="warn">會一併刪除這個組合的計畫與交易紀錄。資料只存在本機，刪除後無法還原。</p>
            <Field label="輸入 App 密碼確認"><input type="password" inputMode="numeric" value={delPin} onChange={(e) => setDelPin(e.target.value)} aria-label="刪除確認密碼" /></Field>
            <button className="danger" onClick={async () => {
              try {
                await passcode.unlock(delPin);
                if ((await run((b) => b.deletePortfolio(id))) !== undefined) go("portfolios");
              } catch (e) {
                setError(describeError(e));
              }
              setDelPin(null);
            }}>確認刪除</button>
          </>
        )}
      </Section>
    </Page>
  );
}
