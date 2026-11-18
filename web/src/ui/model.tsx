import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { BookError, PortfolioBook } from "../app/book";
import { fetchQuotes, listing, snapshots, type Listing, type QuotesFile } from "../app/quotes";
import { PasscodeError, PasscodeManager } from "../app/security";
import { idbStore, requestPersistence, type KV } from "../app/storage";

export type Phase = "loading" | "onboarding" | "locked" | "unlocked";

interface Ctx {
  phase: Phase;
  book: PortfolioBook | null;
  passcode: PasscodeManager;
  rev: number;
  view: "TWD" | "USD";
  setView: (v: "TWD" | "USD") => void;
  includeDividends: boolean;
  setIncludeDividends: (v: boolean) => void;
  error: string | null;
  setError: (e: string | null) => void;
  /** 執行修改；成功時回傳結果（無回傳值的動作回傳 true），失敗時顯示錯誤並回傳 undefined */
  run: <T>(fn: (b: PortfolioBook) => Promise<T>) => Promise<T | true | undefined>;
  unlocked: () => void;
  lock: () => void;
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
  if (e instanceof PasscodeError) {
    switch (e.code) {
      case "NOT_FOUR_DIGITS": return "密碼需為 4 位數字";
      case "TOO_SIMPLE": return "密碼太簡單（例如 0000、1234），請換一組";
      case "MISMATCH": return "兩次輸入的密碼不同";
      case "WRONG_PASSCODE": return "密碼錯誤";
      case "WRONG_RECOVERY_CODE": return `復原碼不正確（第 ${e.detail} 次）`;
      case "INVALID_RECOVERY_FORMAT": return "復原碼格式不正確（應為 20 個英數字）";
      case "LOCKED": return `嘗試次數過多，請於 ${e.detail} 秒後再試`;
      case "CHALLENGE_FAILED": return "復原碼核對失敗";
      case "DATA_LOSS_NOT_ACKNOWLEDGED": return "請先勾選資料保存說明";
      default: return e.code;
    }
  }
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
  const passcode = useMemo(() => new PasscodeManager(kv), [kv]);
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
  const hiddenAt = useRef<number | null>(null);

  useEffect(() => {
    (async () => {
      try {
        setBook(await PortfolioBook.open(kv));
        setPhase((await passcode.isConfigured()) ? "locked" : "onboarding");
      } catch (e) {
        setError(`無法讀取本機資料：${describeError(e)}`);
      }
    })();
  }, [kv, passcode]);

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

  const unlocked = useCallback(() => {
    setPhase("unlocked");
    requestPersistence().then(setPersisted).catch(() => setPersisted(null));
    if (book) book.generatePending().then(() => setRev((x) => x + 1)).catch((e) => setError(describeError(e)));
    refresh(false);
  }, [book, refresh]);

  // 切到背景時記錄時間；回來時超過設定秒數就重新上鎖（docs/10 §4）
  useEffect(() => {
    const onVis = async () => {
      if (document.visibilityState === "hidden") hiddenAt.current = Date.now();
      else if (phase === "unlocked" && hiddenAt.current !== null) {
        const s = await passcode.state();
        if ((Date.now() - hiddenAt.current) / 1000 >= (s?.relockAfterSeconds ?? 60)) setPhase("locked");
        hiddenAt.current = null;
      }
    };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, [phase, passcode]);

  const value: Ctx = {
    phase, book, passcode, rev, view, includeDividends, error, setError, run, unlocked, refresh, refreshing, refreshError, quotes, persisted,
    listingRows: useMemo(() => (quotes ? listing(quotes) : []), [quotes]),
    setView: (v) => {
      setViewState(v);
      savePref("view", v);
    },
    setIncludeDividends: (v) => {
      setIncDivState(v);
      savePref("incDiv", v);
    },
    lock: () => setPhase("locked"),
    wipe: async (confirmation) => {
      if (!(await passcode.wipe(confirmation))) return false;
      await book?.wipeAll();
      setRev((x) => x + 1);
      setPhase("onboarding");
      return true;
    },
  };
  return <C.Provider value={value}>{children}</C.Provider>;
}
