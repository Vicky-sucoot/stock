import { useMemo, useState } from "react";
import { addDays, type ISODate } from "../core/date";
import type { MonthPoint } from "../core/snapshots";
import type { Overview } from "../core/valuation";
import { Page, Row, Section, Segmented, Tag } from "./components";
import { dateTime, money, num, pct, qty, shortDate, signedMoney } from "./fmt";
import { useApp } from "./model";
import { go } from "./router";

const MARKET: Record<string, string> = { TW: "台股／台灣 ETF", US: "美股／美國 ETF", JP: "日股／日本 ETF", FUND_TW: "基金" };

export function Home() {
  const { book, rev, view, setView, refresh, refreshing } = useApp();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const result = useMemo(() => book!.overview(view), [book, rev, view]);
  return (
    <Page title="總覽" action={
      <button className="link" onClick={() => refresh(true)} disabled={refreshing} aria-label="更新行情">{refreshing ? "更新中…" : "更新"}</button>
    }>
      <Segmented label="檢視幣別" value={view} onChange={setView} options={[["TWD", "台幣 TWD"], ["USD", "美元 USD"]]} />
      <PlanCard pending={result.pending} />
      <Kpis ov={result.overview} />
      <Section title="損益走勢（每月）"><MonthlyChart /></Section>
      <Section title="匯率"><FxRows /></Section>
      {result.overview.rows.length > 0 && <Allocation ov={result.overview} />}
      <Section title="投資組合">
        {book!.activePortfolios.map((p) => (
          <Row key={p.id} onClick={() => go("portfolio", p.id)} label={<><span className="dot" style={{ background: p.colorHex }} />{p.name}</>}
            value={p.includeInOverview ? "›" : "未納入總覽 ›"} />
        ))}
        <button className="link" onClick={() => go("portfolio-new")}>＋ 新增投資組合</button>
      </Section>
      {result.overview.rows.some((r) => !r.quantity.isZero()) && <Holdings ov={result.overview} />}
      <DataStatus ov={result.overview} broken={result.brokenHoldings} />
    </Page>
  );
}

function PlanCard({ pending }: { pending: { count: number; estimatedTotal: import("../core/decimal").Dec; unconvertibleCount: number } }) {
  const { book, view } = useApp();
  const upcoming = useMemo(() => {
    const out: { key: string; date: ISODate; title: string; amount: string }[] = [];
    for (const plan of book!.data.plans) {
      if (plan.paused) continue;
      const inst = book!.instrument(plan.instrumentId);
      if (!inst) continue;
      const limit = addDays(book!.today(inst.market), 7);
      for (const o of book!.previewUpcoming(plan, 3)) {
        if (o.scheduledDate > limit) continue;
        const pname = book!.data.portfolios.find((p) => p.id === plan.portfolioId)?.name ?? "";
        out.push({ key: plan.id + o.periodKey, date: o.scheduledDate, title: `${pname}・${inst.name}`,
                   amount: plan.amountMode === "AMOUNT" ? `${plan.currency} ${plan.amount}` : `${plan.amount} 單位` });
      }
    }
    return out.sort((a, b) => (a.date < b.date ? -1 : 1));
  }, [book]);
  return (
    <Section title="定期定額">
      {pending.count > 0 ? (
        <Row onClick={() => go("pending")} label={<><span className="dot red" />{pending.count} 筆待確認</>}
          value={`約 ${money(pending.estimatedTotal, view)} ›`}
          sub={pending.unconvertibleCount ? `${pending.unconvertibleCount} 筆無法估算金額（缺價格或匯率）` : undefined} />
      ) : <p className="muted">目前沒有待確認的期數</p>}
      {upcoming.length > 0 && <h3>近 7 天</h3>}
      {upcoming.map((u) => <Row key={u.key} label={`${shortDate(u.date)} ${u.title}`} value={u.amount} />)}
    </Section>
  );
}

function Kpis({ ov }: { ov: Overview }) {
  const { view, includeDividends, setIncludeDividends } = useApp();
  const pnl = includeDividends ? ov.pnlIncDiv : ov.pnlExDiv;
  const ret = includeDividends ? ov.returnIncDiv : ov.returnExDiv;
  // 台股慣例紅漲綠跌；零為中性
  const tone = (v: { isNegative(): boolean; isZero(): boolean } | null) => (!v || v.isZero() ? "" : v.isNegative() ? "down" : "up");
  return (
    <Section>
      <p className="muted">總資產</p>
      <p className="big num" data-testid="total-assets">{money(ov.totalAssets, view)}</p>
      <div className="kpis">
        <div><span>累計投入</span><b className="num">{money(ov.investedCurrent, view)}</b></div>
        <div><span>損益</span><b className={`num ${tone(pnl)}`}>{signedMoney(pnl, view)}</b></div>
        <div><span>報酬率</span><b className={`num ${tone(ret)}`}>{pct(ret)}</b></div>
      </div>
      <label className="check"><input type="checkbox" checked={includeDividends} onChange={(e) => setIncludeDividends(e.target.checked)} /><span>損益含股利</span></label>
      <p className="foot">報酬率 = 損益 ÷ 歷史總投入 {money(ov.historicalInvested, view)}；台股慣例紅漲綠跌</p>
    </Section>
  );
}

function MonthlyChart() {
  const { book, rev, view } = useApp();
  const [usdOnly, setUsdOnly] = useState(false);
  const [sel, setSel] = useState<number | null>(null);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const pts: MonthPoint[] = useMemo(() => book!.monthlyPoints(view, view === "USD" && usdOnly ? "USD" : null), [book, rev, view, usdOnly]);
  const ccy = view === "USD" && usdOnly ? "USD" : view;
  return (
    <>
      {view === "USD" && <label className="check"><input type="checkbox" checked={usdOnly} onChange={(e) => setUsdOnly(e.target.checked)} /><span>只看美元計價資產（原幣、不換算）</span></label>}
      {pts.length === 0 ? <p className="muted">新增交易後會顯示每月走勢</p> : <LineChart pts={pts} sel={sel} onSel={setSel} />}
      {sel !== null && pts[sel] && (
        <p className="foot">
          {pts[sel].month}：市值 {money(pts[sel].marketValue, ccy)}，投入 {money(pts[sel].investedCurrent, ccy)}，損益 {signedMoney(pts[sel].pnlExDiv, ccy)}
          {pts[sel].estimated && `（推估：${[...pts[sel].estimatedItems, ...pts[sel].missingFx.map((c) => `缺 ${c} 匯率`)].join("、")}）`}
        </p>
      )}
      {pts.length > 0 && <p className="foot">實線為市值、虛線為累計投入；灰點表示該月使用推估價格或匯率。點選圖表查看數值。</p>}
    </>
  );
}

function LineChart({ pts, sel, onSel }: { pts: MonthPoint[]; sel: number | null; onSel: (i: number) => void }) {
  const W = 320, H = 160, P = 8;
  const vals = pts.flatMap((p) => [p.marketValue.toNumber(), p.investedCurrent.toNumber()]);
  const max = Math.max(...vals, 1), min = Math.min(...vals, 0);
  const x = (i: number) => P + (pts.length === 1 ? (W - 2 * P) / 2 : (i * (W - 2 * P)) / (pts.length - 1));
  const y = (v: number) => H - P - ((v - min) * (H - 2 * P)) / (max - min || 1);
  const path = (f: (p: MonthPoint) => number) => pts.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(f(p)).toFixed(1)}`).join(" ");
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="chart" role="img" aria-label="每月市值與累計投入走勢"
      onClick={(e) => {
        const r = (e.currentTarget as SVGSVGElement).getBoundingClientRect();
        const rel = ((e.clientX - r.left) / r.width) * W;
        onSel(Math.max(0, Math.min(pts.length - 1, Math.round(((rel - P) / (W - 2 * P)) * (pts.length - 1)))));
      }}>
      <path d={path((p) => p.investedCurrent.toNumber())} className="invested" />
      <path d={path((p) => p.marketValue.toNumber())} className="value" />
      {pts.map((p, i) => <circle key={p.month} cx={x(i)} cy={y(p.marketValue.toNumber())} r={i === sel ? 4.5 : 3} className={p.estimated ? "est" : "pt"} />)}
      <text x={P} y={H - 1} className="axis">{pts[0].month}</text>
      <text x={W - P} y={H - 1} className="axis" textAnchor="end">{pts[pts.length - 1].month}</text>
    </svg>
  );
}

function FxRows() {
  const { book, rev } = useApp();
  void rev;
  return (
    <>
      {["USD", "JPY"].map((c) => {
        const [r, src] = book!.currentFx(c);
        return <Row key={c} onClick={() => go("manual", "fx", c)} label={`${c}/TWD`}
          value={<>{r ? num(r, c === "JPY" ? 4 : 3) : "未設定"} {src === "MANUAL" && <Tag text="手動" />}</>} />;
      })}
      <button className="link" onClick={() => go("fx-help")}>換算方式說明</button>
    </>
  );
}

function Allocation({ ov }: { ov: Overview }) {
  const { book, view } = useApp();
  const groups = new Map<string, import("../core/decimal").Dec>();
  for (const r of ov.rows) {
    if (!r.marketValueView) continue;
    const m = MARKET[book!.instrument(r.instrumentId)?.market ?? ""] ?? "其他";
    groups.set(m, (groups.get(m) ?? r.marketValueView.times(0)).plus(r.marketValueView));
  }
  return (
    <Section title="資產配置">
      {[...groups.entries()].map(([k, v]) => (
        <Row key={k} label={k} value={`${money(v, view)}　${ov.totalAssets.isZero() ? "—" : v.div(ov.totalAssets).times(100).toFixed(1) + "%"}`} />
      ))}
    </Section>
  );
}

function Holdings({ ov }: { ov: Overview }) {
  const { book } = useApp();
  return (
    <Section title="持有標的平均成本">
      {ov.rows.filter((r) => !r.quantity.isZero()).map((r) => {
        const inst = book!.instrument(r.instrumentId);
        return (
          <Row key={r.instrumentId} label={inst ? `${inst.symbol} ${inst.name}` : "?"} value={money(r.marketValue, r.currency)}
            sub={<>數量 {qty(r.quantity)}・均價 {num(r.avgCost)}・現價 {num(r.price)} {r.priceSource === "MANUAL" && <Tag text="手動" />}{(r.priceSource === "LAST_TRADE" || r.priceSource === "COST") && <Tag text="估計" />}</>} />
        );
      })}
    </Section>
  );
}

function DataStatus({ ov, broken }: { ov: Overview; broken: string[] }) {
  const { book, refreshError, quotes } = useApp();
  const latest = Object.values(book!.data.priceCache).map((c) => c.dataDate).sort().pop();
  return (
    <Section title="資料狀態">
      <p className="foot">最後更新：{dateTime(book!.data.lastRefresh.TW_QUOTES)}</p>
      {latest && <p className="foot">行情資料日：{shortDate(latest)}（官方收盤資料可能延遲 1 個交易日以上）</p>}
      {ov.estimatedInstruments.length > 0 && <p className="foot">{ov.estimatedInstruments.length} 檔使用估計價格</p>}
      {ov.missingFx.length > 0 && <p className="foot warn">缺少匯率：{ov.missingFx.join("、")}，相關資產未計入。請在匯率區手動輸入。</p>}
      {broken.length > 0 && <p className="foot error">交易資料異常：{broken.join("、")}</p>}
      {refreshError && <p className="foot warn">行情更新失敗：{refreshError}（顯示上次資料）</p>}
      {quotes?.sources.map((s) => <p className="foot" key={s.id}>{s.attribution}</p>)}
    </Section>
  );
}

export function FxHelp() {
  return (
    <Page title="換算方式" onBack>
      <Section title="換算方式">
        <p>台幣檢視：原幣金額 × 原幣兌台幣匯率</p>
        <p>美元檢視：原幣金額 × 原幣兌台幣匯率 ÷ 美元兌台幣匯率</p>
        <p>成本與投入以目前匯率重新估算（docs/02 §2.2）</p>
        <p>範例：AAPL 10 股 × 190 USD × 32.10 = NT$60,990</p>
      </Section>
      <Section title="匯率來源">
        <p>目前沒有已確認授權、且可免費自動取得的匯率來源，請手動輸入。手動匯率會一直沿用，直到你再次修改或改回自動。</p>
      </Section>
    </Page>
  );
}
