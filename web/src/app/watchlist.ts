/**
 * 每日名單（建議買入／建議賣出）：後端以使用者的通關密語加密，網站上只有密文。
 * 這裡用瀏覽器內建 WebCrypto 解密（PBKDF2-SHA256 → AES-256-GCM），密語不會送出這支手機。
 */

export interface EncryptedBlob {
  v: 1;
  alg: "PBKDF2-SHA256/AES-256-GCM";
  iter: number;
  salt: string;
  iv: string;
  ct: string;
}

export type ListType = "BULLISH" | "BEARISH" | "UNCERTAIN";

export interface FlowRow {
  trade_date: string;
  fi_buy: number;
  fi_sell: number;
  fi_net: number;
  source_id: string;
  source_url: string;
  fetched_at: string;
}

export interface NewsItem {
  announcement_id: number;
  subject: string;
  published_at: string;
  source_url: string;
  attribution: string | null;
  is_stale: boolean;
  counted: boolean;
  polarity: number | null;
  confidence: string | null;
  method: string | null;
  rationale: string;
  flags: string[];
}

export interface Entry {
  list_type: ListType;
  rank: number;
  symbol: string;
  name: string;
  board: string;
  score_total: number | null;
  score_foreign: number | null;
  score_news: number | null;
  reason_short: string;
  flags: string[];
  evidence: {
    foreign: null | {
      rows: FlowRow[];
      streak: number;
      amount_estimated: string | null;
      amount_note: string;
      ratio_of_volume: string | null;
      F: number;
      rule_F: number | null;
      method?: "CLAUDE" | "RULE";
      claude?: null | { score: number; confidence: string; reason: string };
    };
    news: null | { N: number; formula: string; items: NewsItem[] };
    rule_version: string;
    disclaimer: string;
  };
}

export interface Watchlist {
  run_id: string;
  data_date: string;
  status: "OK" | "PARTIAL" | "FAILED";
  coverage: Record<string, boolean | number>;
  rule_version: string;
  stats: Record<string, unknown>;
  generated_at: string | null;
  disclaimer: string;
  entries: Entry[];
}

export const LIST_LABEL: Record<ListType, string> = {
  BULLISH: "建議買入",
  BEARISH: "建議賣出／避開",
  UNCERTAIN: "訊號衝突／資料不足",
};

export const FLAG_LABEL: Record<string, string> = {
  HISTORY_INSUFFICIENT: "歷史資料不足",
  NO_QUOTE: "缺當日行情",
  LOW_CONFIDENCE: "訊息判定信心低",
  SIGNAL_CONFLICT: "訊號衝突",
  LLM_FAILED: "Claude 評分失敗，改用規則分",
  LLM_SIGN_MISMATCH: "Claude 方向與當日買賣超相反，改用規則分",
  MODEL_RULE_CONFLICT: "Claude 與規則判定相反，不計分",
  NEGATION_DISAGREE: "否定語句判斷不一致",
  RULE_UNDECIDED: "規則無法判定",
};

export class WrongPassphrase extends Error {
  constructor() {
    super("通關密語不正確");
  }
}

const b64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

export function isBlob(x: unknown): x is EncryptedBlob {
  const o = x as EncryptedBlob;
  return !!o && o.v === 1 && o.alg === "PBKDF2-SHA256/AES-256-GCM" && typeof o.iter === "number"
    && typeof o.salt === "string" && typeof o.iv === "string" && typeof o.ct === "string";
}

export async function decryptWatchlist(blob: EncryptedBlob, passphrase: string): Promise<Watchlist> {
  const subtle = globalThis.crypto.subtle;
  const base = await subtle.importKey("raw", new TextEncoder().encode(passphrase), "PBKDF2", false, ["deriveKey"]);
  const key = await subtle.deriveKey({ name: "PBKDF2", hash: "SHA-256", salt: b64(blob.salt), iterations: blob.iter },
    base, { name: "AES-GCM", length: 256 }, false, ["decrypt"]);
  let pt: ArrayBuffer;
  try {
    pt = await subtle.decrypt({ name: "AES-GCM", iv: b64(blob.iv) }, key, b64(blob.ct));
  } catch {
    throw new WrongPassphrase();
  }
  return JSON.parse(new TextDecoder().decode(pt)) as Watchlist;
}

/** 下載密文；網站尚未發布名單（未設定密語）時回傳 null。 */
export async function fetchWatchlist(url: string): Promise<EncryptedBlob | null> {
  const r = await fetch(url, { cache: "no-cache" });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`無法下載名單（HTTP ${r.status}）`);
  const j = await r.json().catch(() => null);
  if (!isBlob(j)) throw new Error("名單檔格式不正確");
  return j;
}

export function byList(w: Watchlist): Record<ListType, Entry[]> {
  const out: Record<ListType, Entry[]> = { BULLISH: [], BEARISH: [], UNCERTAIN: [] };
  for (const e of w.entries) out[e.list_type]?.push(e);
  for (const k of Object.keys(out) as ListType[]) out[k].sort((a, b) => a.rank - b.rank);
  return out;
}
