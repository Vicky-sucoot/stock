import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { BookError, PortfolioBook } from "../app/book";
import { fetchQuotes, listing, snapshots, type Listing, type QuotesFile } from "../app/quotes";
import { idbStore, requestPersistence, type KV } from "../app/storage";

export type Phase = "loading" | "onboarding" | "ready";

/** 使用者已勾選資料保存說明（首次設定完成）的標記 */
export const ACK_KEY = "onboarding.ack.v1";
/** 舊版密碼鎖的安全狀態；密碼鎖已依使用者決定關閉，啟動時清除 */
const LEGACY_SECURITY_KEY = "security.state.v1";
export const WIPE_TEXT = "清除全部資料";

interface Ctx {
  phase: Phase;
  book: PortfolioBook | null;
  rev: number;
  view: "TWD" | "USD";
  setView: (v: "TWD" | "USD") => void;
  includeDividends: boolean;
  setIncludeDividends: (v: boolean) => void;
  error: string | null;
  setError: (e: string | null) => void;
  /** 執行修改；成功時回傳結果（無回傳值的動作回傳 true），失敗時顯示錯誤並回傳 undefined */
  run: <T>(fn: (b: PortfolioBook) => Promise<T>) => Promise<T | true | undefined>;
  /** 首次設定：記錄已了解資料保存方式，並建立第一個投資組合 */
  completeOnboarding: (portfolioName: string) => Promise<boolean>;
  refresh: (force?: boolean) => Promise<void>;
  refreshing: boolean;
  refreshError: string | null;
  quotes: QuotesFile | null;
  listingRows: Listing[];
  persisted: boolean | null;
  wipe: (confirmation: string) => Promise<boolean>;
}

const C = createContext<Ctx | null>(null);
export const useApp = () => useContext(C)!;

export function describeError(e: unknown): string {
  if (e instanceof BookError) return e.message;
  return e instanceof Error ? e.message : String(e);
}

const pref = <T,>(k: string, d: T): T => {
  try {
    const v = localStorage.getItem(k);
    return v === null ? d : (JSON.parse(v) as T);
  } catch {
    return d;
  }
};
const savePref = (k: string, v: unknown) => {
  try {
    localStorage.setItem(k, JSON.stringify(v));
  } catch {
    /* 私密瀏覽等情況忽略 */
  }
};

export function AppProvider({ children, kv = idbStore, quotesUrl = "data/quotes.json" }: { children: ReactNode; kv?: KV; quotesUrl?: string }) {
  const [phase, setPhase] = useState<Phase>("loading");
  const [book, setBook] = useState<PortfolioBook | null>(null);
  const [rev, setRev] = useState(0);
  const [view, setViewState] = useState<"TWD" | "USD">(pref("view", "TWD"));
  const [includeDividends, setIncDivState] = useState<boolean>(pref("incDiv", true));
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const [quotes, setQuotes] = useState<QuotesFile | null>(null);
  const [persisted, setPersisted] = useState<boolean | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const b = await PortfolioBook.open(kv);
        await kv.del(LEGACY_SECURITY_KEY);
        setBook(b);
        const done = (await kv.get<boolean>(ACK_KEY)) || b.data.portfolios.length > 0;
        setPhase(done ? "ready" : "onboarding");
      } catch (e) {
        setError(`無法讀取本機資料：${describeError(e)}`);
      }
    })();
  }, [kv]);

  const run = useCallback(async <T,>(fn: (b: PortfolioBook) => Promise<T>) => {
    if (!book) return undefined;
    try {
      const r = await fn(book);
      setRev((x) => x + 1);
      return r === undefined ? true : r;
    } catch (e) {
      setError(describeError(e));
      return undefined;
    }
  }, [book]);

  const refresh = useCallback(async (force = false) => {
    if (!book) return;
    const tw = () => new Set(book.data.instruments.filter((i) => i.market === "TW").map((i) => i.symbol));
    const last = book.data.lastRefresh.TW_QUOTES;
    if (!force && last && Date.now() - new Date(last).getTime() < 15 * 60_000 && quotes) {
      // 不重新下載，但把已載入的行情套用到新加入的標的
      await book.applyQuotes(snapshots(quotes, tw()));
      setRev((x) => x + 1);
      return;
    }
    setRefreshing(true);
    try {
      const f = await fetchQuotes(quotesUrl);
      setQuotes(f);
      await book.applyQuotes(snapshots(f, tw()));
      await book.markRefreshed("TW_QUOTES");
      setRefreshError(null);
    } catch (e) {
      setRefreshError(describeError(e));
    } finally {
      setRefreshing(false);
      setRev((x) => x + 1);
    }
  }, [book, quotes, quotesUrl]);

  // 進入 App 時：請求持久儲存、補產生待確認期數、更新行情（不需要密碼）
  useEffect(() => {
    if (phase !== "ready" || !book) return;
    requestPersistence().then(setPersisted).catch(() => setPersisted(null));
    book.generatePending().then(() => setRev((x) => x + 1)).catch((e) => setError(describeError(e)));
    refresh(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase, book]);

  const value: Ctx = {
    phase, book, rev, view, includeDividends, error, setError, run, refresh, refreshing, refreshError, quotes, persisted,
    listingRows: useMemo(() => (quotes ? listing(quotes) : []), [quotes]),
    setView: (v) => {
      setViewState(v);
      savePref("view", v);
    },
    setIncludeDividends: (v) => {
      setIncDivState(v);
      savePref("incDiv", v);
    },
    completeOnboarding: async (name) => {
      if (!book) return false;
      try {
        await book.createPortfolio(name);
        await kv.set(ACK_KEY, true);
        setRev((x) => x + 1);
        setPhase("ready");
        return true;
      } catch (e) {
        setError(describeError(e));
        return false;
      }
    },
    wipe: async (confirmation) => {
      if (confirmation !== WIPE_TEXT) return false;
      await book?.wipeAll();
      await kv.del(ACK_KEY);
      setRev((x) => x + 1);
      setPhase("onboarding");
      return true;
    },
  };
  return <C.Provider value={value}>{children}</C.Provider>;
}
