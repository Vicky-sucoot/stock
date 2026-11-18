// 台股與台灣 ETF 收盤價：由 GitHub Actions 每日從官方 OpenAPI 擷取後，以同站檔案 data/quotes.json 提供。
// （官方 API 不允許瀏覽器跨站讀取，所以不直接呼叫。）
import type { QuoteSnapshot } from "./book";

export interface QuotesFile {
  generated_at: string;
  disclaimer: string;
  sources: { id: string; name: string; attribution: string; url: string; license_url: string; data_date: string | null }[];
  quotes: Record<string, [string, "TWSE" | "TPEX", string | null, string]>;
}

export interface Listing {
  symbol: string;
  name: string;
  board: "TWSE" | "TPEX";
}

export async function fetchQuotes(url = "data/quotes.json", fetcher: typeof fetch = fetch): Promise<QuotesFile> {
  const r = await fetcher(url, { cache: "no-cache" });
  if (!r.ok) throw new Error(`行情檔讀取失敗（HTTP ${r.status}）`);
  const data = (await r.json()) as QuotesFile;
  if (!data || typeof data.quotes !== "object") throw new Error("行情檔格式錯誤");
  return data;
}

export function listing(f: QuotesFile): Listing[] {
  return Object.entries(f.quotes).map(([symbol, [name, board]]) => ({ symbol, name, board }));
}

export function snapshots(f: QuotesFile, symbols: Set<string>): QuoteSnapshot[] {
  const src = Object.fromEntries(f.sources.map((s) => [s.id, s]));
  const out: QuoteSnapshot[] = [];
  for (const sym of symbols) {
    const q = f.quotes[sym];
    if (!q || !q[2]) continue;
    const s = src[q[1] === "TWSE" ? "TWSE_STOCK_DAY_ALL" : "TPEX_MAINBOARD_QUOTES"];
    out.push({ market: "TW", symbol: sym, close: q[2], dataDate: q[3], sourceId: s?.id ?? q[1], sourceURL: s?.url ?? "", attribution: s?.attribution ?? "" });
  }
  return out;
}
