import { useCallback, useEffect, useState } from "react";
import {
  byList, decryptWatchlist, fetchWatchlist, FLAG_LABEL, LIST_LABEL, WrongPassphrase,
  type Entry, type ListType, type Watchlist,
} from "../app/watchlist";
import { Field, Page, Row, Section, Tag } from "./components";
import { dateTime } from "./fmt";
import { go } from "./router";

const PASS_KEY = "watch.passphrase.v1";
const readPass = () => { try { return localStorage.getItem(PASS_KEY) ?? ""; } catch { return ""; } };
const savePass = (v: string | null) => {
  try { if (v === null) localStorage.removeItem(PASS_KEY); else localStorage.setItem(PASS_KEY, v); } catch { /* 私密瀏覽 */ }
};

/** 解密後的名單只放在記憶體（明細頁共用），不寫入本機儲存。 */
let cache: Watchlist | null = null;

type State =
  | { k: "loading" }
  | { k: "none" }
  | { k: "need-pass"; wrong?: boolean }
  | { k: "error"; msg: string }
  | { k: "ok"; w: Watchlist };

function useWatchlist(url: string) {
  const [st, setSt] = useState<State>(cache ? { k: "ok", w: cache } : { k: "loading" });
  const load = useCallback(async (pass: string) => {
    setSt({ k: "loading" });
    try {
      const blob = await fetchWatchlist(url);
      if (!blob) return setSt({ k: "none" });
      if (!pass) return setSt({ k: "need-pass" });
      cache = await decryptWatchlist(blob, pass);
      savePass(pass);
      setSt({ k: "ok", w: cache });
    } catch (e) {
      if (e instanceof WrongPassphrase) {
        savePass(null);
        setSt({ k: "need-pass", wrong: true });
      } else setSt({ k: "error", msg: e instanceof Error ? e.message : String(e) });
    }
  }, [url]);
  useEffect(() => { if (!cache) load(readPass()); }, [load]);
  return { st, load };
}

const signed = (n: number | null) => (n === null ? "—" : n > 0 ? `+${n}` : String(n));
const tone = (t: ListType) => (t === "BULLISH" ? "up" : t === "BEARISH" ? "down" : "warn");

function EntryRow({ e }: { e: Entry }) {
  return (
    <Row
      label={<>{e.symbol} {e.name}{e.flags.includes("HISTORY_INSUFFICIENT") && <Tag text="歷史不足" />}</>}
      value={<span className={tone(e.list_type)}>{signed(e.score_total)}</span>}
      sub={e.reason_short}
      onClick={() => go("watch-item", e.symbol)}
    />
  );
}

function ListCard({ t, items }: { t: ListType; items: Entry[] }) {
  const [all, setAll] = useState(false);
  const shown = all ? items : items.slice(0, 5);
  return (
    <Section title={`${LIST_LABEL[t]}（${items.length}）`}>
      {items.length === 0 ? <p className="muted">今天沒有符合條件的標的</p> : shown.map((e) => <EntryRow key={e.symbol} e={e} />)}
      {items.length > 5 && (
        <button className="link" onClick={() => setAll(!all)}>{all ? "只看前 5 檔" : `展開全部 ${Math.min(items.length, 10)} 檔`}</button>
      )}
    </Section>
  );
}

function PassForm({ wrong, onSubmit }: { wrong?: boolean; onSubmit: (p: string) => void }) {
  const [p, setP] = useState("");
  return (
    <Section title="輸入通關密語" footer="名單以你自訂的通關密語加密後才放上網站；密語只存在這支手機，不會送出。密語就是 GitHub Secret「WATCHLIST_PASSPHRASE」的內容。">
      {wrong && <p className="error">通關密語不正確</p>}
      <Field label="通關密語">
        <input type="password" autoComplete="current-password" value={p} onChange={(e) => setP(e.target.value)} aria-label="通關密語" />
      </Field>
      <button className="primary" disabled={!p} onClick={() => onSubmit(p)}>解鎖名單</button>
    </Section>
  );
}

export function Watch({ url = "data/watchlist.enc.json" }: { url?: string }) {
  const { st, load } = useWatchlist(url);
  return (
    <Page title="每日名單" action={st.k === "ok" ? <button className="link" onClick={() => { cache = null; load(readPass()); }}>重新整理</button> : undefined}>
      {st.k === "loading" && <p className="muted center">載入中…</p>}
      {st.k === "none" && (
        <Section title="尚未發布">
          <p>網站上目前沒有名單檔。需要先在 GitHub 設定通關密語（WATCHLIST_PASSPHRASE），之後每個交易日自動產生並加密發布。</p>
        </Section>
      )}
      {st.k === "error" && <Section title="無法載入"><p className="error">{st.msg}</p><button className="link" onClick={() => load(readPass())}>再試一次</button></Section>}
      {st.k === "need-pass" && <PassForm wrong={st.wrong} onSubmit={load} />}
      {st.k === "ok" && <Lists w={st.w} onForget={() => { savePass(null); cache = null; load(""); }} />}
    </Page>
  );
}

function Lists({ w, onForget }: { w: Watchlist; onForget: () => void }) {
  const g = byList(w);
  const claude = !!w.coverage.llm_foreign;
  return (
    <>
      <Section>
        <p>資料日 {w.data_date}{w.status !== "OK" && <Tag text={w.status === "PARTIAL" ? "部分資料" : "資料失敗"} />}</p>
        <p className="foot">
          評分：{claude ? "外資動向與訊息情緒由 Claude 評分，規則分做交叉檢查與備援" : "規則評分（Claude 未啟用）"}｜
          外資資料只有上櫃；上市股票列為資料不足｜訊息只用公開資訊觀測站重大訊息
        </p>
      </Section>
      {(["BULLISH", "BEARISH", "UNCERTAIN"] as ListType[]).map((t) => <ListCard key={t} t={t} items={g[t]} />)}
      <Section>
        <p className="foot">名稱「建議買入／建議賣出」依使用者要求，實際是依公開資料的機械式篩選，不構成投資建議，不保證準確或獲利，本 App 不會下單。產生時間 {dateTime(w.generated_at)}</p>
        <button className="link danger" onClick={onForget}>在這支手機忘記通關密語</button>
      </Section>
    </>
  );
}

const lots = (shares: number) => `${shares >= 0 ? "買" : "賣"} ${Math.abs(Math.round(shares / 1000)).toLocaleString("zh-TW")} 張`;

export function WatchItem({ symbol, url = "data/watchlist.enc.json" }: { symbol: string; url?: string }) {
  const { st, load } = useWatchlist(url);
  if (st.k !== "ok") {
    return (
      <Page title={symbol} onBack>
        {st.k === "loading" && <p className="muted center">載入中…</p>}
        {st.k === "need-pass" && <PassForm wrong={st.wrong} onSubmit={load} />}
        {(st.k === "none" || st.k === "error") && <Section><p className="muted">無法載入名單，請回到名單頁。</p></Section>}
      </Page>
    );
  }
  const w = st.w;
  const e = w.entries.find((x) => x.symbol === symbol);
  if (!e) return <Page title={symbol} onBack><Section><p className="muted">今天的名單沒有這個標的。</p></Section></Page>;
  const f = e.evidence.foreign;
  const n = e.evidence.news;
  return (
    <Page title={`${e.symbol} ${e.name}`} onBack>
      <Section title={LIST_LABEL[e.list_type]}>
        <Row label="綜合分" value={<span className={tone(e.list_type)}>{signed(e.score_total)}</span>} />
        <Row label="外資分" value={signed(e.score_foreign)} sub={f ? (f.method === "CLAUDE" ? `Claude 評分（規則分 ${signed(f.rule_F)}）` : "規則評分") : undefined} />
        <Row label="訊息分" value={signed(e.score_news)} />
        <p>{e.reason_short}</p>
        {e.flags.map((x) => <Tag key={x} text={FLAG_LABEL[x] ?? x} />)}
      </Section>
      {f && (
        <Section title="外資及陸資買賣超（不含自營商）" footer={`${f.amount_note}。資料日 ${w.data_date}`}>
          {f.claude && <p>Claude：{f.claude.reason}（{signed(f.claude.score)}，信心 {f.claude.confidence}）</p>}
          <p className="foot">連續 {f.streak} 日同方向；估計金額 {f.amount_estimated ? `${(Number(f.amount_estimated) / 1e6).toFixed(1)} 百萬元` : "—"}；占成交量 {f.ratio_of_volume ? `${(Number(f.ratio_of_volume) * 100).toFixed(1)}%` : "—"}</p>
          {f.rows.map((r) => <Row key={r.trade_date} label={r.trade_date} value={lots(r.fi_net)} />)}
          {f.rows[0] && <a href={f.rows[0].source_url} target="_blank" rel="noreferrer">官方來源</a>}
        </Section>
      )}
      {n && (
        <Section title="公司重大訊息（公開資訊觀測站）" footer={n.formula}>
          {n.items.length === 0 && <p className="muted">無相關重大訊息</p>}
          {n.items.map((i) => (
            <div key={i.announcement_id} className="row">
              <div className="row-main">
                <span>{i.subject}</span>
                <span className={i.polarity ? (i.polarity > 0 ? "up" : "down") : "muted"}>{i.polarity === null ? "—" : i.polarity > 0 ? "利多" : i.polarity < 0 ? "利空" : "中性"}</span>
              </div>
              <div className="row-sub">
                {dateTime(i.published_at)}｜{i.method ? (i.method === "RULE+LLM" ? "Claude 判定｜" : "規則判定｜") : ""}{i.rationale}
                {!i.counted && "｜不計分"}
                {i.flags.map((x) => <Tag key={x} text={FLAG_LABEL[x] ?? x} />)}
                {" "}<a href={i.source_url} target="_blank" rel="noreferrer">來源</a>
              </div>
            </div>
          ))}
        </Section>
      )}
      <Section footer={e.evidence.disclaimer}><p className="foot">規則版本 {e.evidence.rule_version}</p></Section>
    </Page>
  );
}
