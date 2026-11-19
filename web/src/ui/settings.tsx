import { useState } from "react";
import { fxKey, parseDecimal } from "../app/book";
import { DecimalInput, Field, Page, Section } from "./components";
import { localToday } from "./fmt";
import { useApp, WIPE_TEXT } from "./model";
import { back, go } from "./router";

/** 手動設定價格、淨值或匯率：持續有效，直到使用者再次修改或改回自動（docs/05 §3） */
export function ManualValue({ kind, id }: { kind: "price" | "fx"; id: string }) {
  const { book, run } = useApp();
  const key = kind === "price" ? id : fxKey(id);
  const inst = kind === "price" ? book!.instrument(id) : undefined;
  const active = book!.activeOverride(key);
  const [value, setValue] = useState(active?.value ?? "");
  const [date, setDate] = useState(localToday());
  const [note, setNote] = useState("");
  const label = kind === "price" ? `${inst?.symbol ?? ""} 價格（${inst?.currency ?? ""}）` : `1 ${id} = ? TWD`;
  return (
    <Page title="手動設定" onBack action={<button className="link" disabled={!parseDecimal(value)} onClick={async () => {
      const ok = kind === "price" ? await run((b) => b.setManualPrice(id, value, date, note || undefined)) : await run((b) => b.setManualFx(id, value, date, note || undefined));
      if (ok !== undefined) back();
    }}>儲存</button>}>
      <Section footer="手動值會一直沿用，自動更新不會覆蓋；之後可再次修改或改回自動。月損益圖中，生效日之後的月份都使用此值。">
        <DecimalInput label={label} value={value} onChange={setValue} />
        <Field label="生效日"><input type="date" value={date} onChange={(e) => setDate(e.target.value)} aria-label="生效日" /></Field>
        <Field label="備註（選填）"><input value={note} onChange={(e) => setNote(e.target.value)} aria-label="備註" /></Field>
        {active && <button className="link" onClick={async () => { if ((await run((b) => b.revertToAuto(key))) !== undefined) back(); }}>改回自動</button>}
      </Section>
    </Page>
  );
}

export function Settings() {
  const { wipe, setError, persisted } = useApp();
  const [wipeText, setWipeText] = useState<string | null>(null);
  return (
    <Page title="設定">
      <Section title="資料來源與聲明">
        <button className="link" onClick={() => go("sources")}>資料來源</button>
        <p className="foot">本 App 只用於規劃與記錄，不連接券商、不下單、不扣款。所提供的資訊不構成投資建議，不保證準確或獲利。</p>
      </Section>
      <Section title="安全與資料">
        <p className="foot">資料只存在這支手機的瀏覽器中，不做雲端備份、不提供匯出。刪除這個網頁 App、清除 Safari 的網站資料或換手機時，資料無法找回。</p>
        <p className="foot">開啟 App 不需要密碼（依使用者設定關閉），請自行保管好手機。</p>
        <p className="foot">建議以 Safari「分享 → 加入主畫面」安裝後使用。持久儲存：{persisted === true ? "已啟用" : persisted === false ? "瀏覽器未同意（請加入主畫面後再開啟）" : "未知"}</p>
        {wipeText === null ? <button className="link danger" onClick={() => setWipeText("")}>清除所有資料並重新開始</button> : (
          <>
            <Field label={`請輸入「${WIPE_TEXT}」`}><input value={wipeText} onChange={(e) => setWipeText(e.target.value)} aria-label="清除確認文字" /></Field>
            <button className="danger" onClick={async () => { if (!(await wipe(wipeText))) setError("確認文字不正確，未清除任何資料"); setWipeText(null); }}>清除</button>
          </>
        )}
      </Section>
    </Page>
  );
}

export function Sources() {
  const { quotes } = useApp();
  return (
    <Page title="資料來源" onBack>
      <Section title="台股與台灣 ETF 收盤價">
        {quotes?.sources.map((s) => <p key={s.id}>{s.name}（資料日 {s.data_date ?? "—"}）<br /><span className="foot">{s.attribution}</span></p>) ?? <p className="muted">尚未載入</p>}
        <p className="foot">由 GitHub Actions 每個交易日自動擷取官方 OpenAPI 後提供；官方資料可能延遲 1 個交易日以上。</p>
        <a href="https://data.gov.tw/license" target="_blank" rel="noreferrer">政府資料開放授權條款</a>
      </Section>
      <Section title="美股、日股、基金、匯率"><p>目前沒有已確認授權、且可在網頁中免費自動取得的來源，請手動輸入。</p></Section>
    </Page>
  );
}
