import { useState } from "react";
import type { Instrument } from "../app/book";
import { Field, Row, Section, Segmented } from "./components";
import { useApp } from "./model";

/** 選擇標的：台股與台灣 ETF 從官方清單搜尋；美股、日股、基金手動新增 */
export function InstrumentPicker({ onPick, onCancel }: { onPick: (i: Instrument) => void; onCancel: () => void }) {
  const { book, listingRows, run, refresh } = useApp();
  const [market, setMarket] = useState<"TW" | "US" | "JP" | "FUND_TW">("TW");
  const [q, setQ] = useState("");
  const [sym, setSym] = useState("");
  const [name, setName] = useState("");
  const [type, setType] = useState("STOCK");
  const match = (s: string, n: string) => !q.trim() || s.toUpperCase().includes(q.trim().toUpperCase()) || n.includes(q.trim());
  const used = book!.data.instruments.filter((i) => i.market === market && match(i.symbol, i.name));
  return (
    <Section title="選擇標的">
      <Segmented label="市場" value={market} onChange={setMarket} options={[["TW", "台股"], ["US", "美股"], ["JP", "日股"], ["FUND_TW", "基金"]]} />
      <Field label="搜尋代號或名稱"><input value={q} onChange={(e) => setQ(e.target.value)} aria-label="搜尋標的" /></Field>
      {used.map((i) => <Row key={i.id} onClick={() => onPick(i)} label={`${i.symbol} ${i.name}`} value="已使用" />)}
      {market === "TW" ? (
        <>
          {listingRows.length === 0 && <p className="muted">官方清單尚未載入。<button className="link" onClick={() => refresh(true)}>重新載入</button></p>}
          {q.trim() && listingRows.filter((l) => match(l.symbol, l.name)).slice(0, 30).map((l) => (
            <Row key={l.symbol} label={`${l.symbol} ${l.name}`} value={l.board === "TWSE" ? "上市" : "上櫃"} onClick={async () => {
              const inst = await run((b) => b.upsertInstrument("TW", l.symbol, l.name, l.symbol.startsWith("00") ? "ETF" : "STOCK", l.board));
              if (inst && inst !== true) {
                await refresh(false); // 立即套用已載入的收盤價
                onPick(inst);
              }
            }} />
          ))}
        </>
      ) : (
        <>
          <Field label={market === "FUND_TW" ? "基金代碼（自訂）" : "代號，例如 AAPL、7203"}><input value={sym} autoCapitalize="characters" onChange={(e) => setSym(e.target.value)} aria-label="代號" /></Field>
          <Field label="名稱"><input value={name} onChange={(e) => setName(e.target.value)} aria-label="標的名稱" /></Field>
          {market !== "FUND_TW" && <Segmented label="類型" value={type} onChange={setType} options={[["STOCK", "股票"], ["ETF", "ETF"]]} />}
          <button className="primary" disabled={!sym.trim()} onClick={async () => {
            const inst = await run((b) => b.upsertInstrument(market, sym, name || sym, market === "FUND_TW" ? "FUND" : type, null, true));
            if (inst && inst !== true) onPick(inst);
          }}>新增</button>
          <p className="foot">美股、日股與基金目前沒有可在網頁中使用的免費自動來源，請手動輸入價格或淨值。</p>
        </>
      )}
      <button className="link" onClick={onCancel}>取消</button>
    </Section>
  );
}
