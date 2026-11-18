// 本機儲存（瀏覽器 IndexedDB）。資料只存在這支裝置，不上傳、不備份（docs/04、docs/10）。
import { del, get, set } from "idb-keyval";

export interface KV {
  get<T>(key: string): Promise<T | undefined>;
  set<T>(key: string, value: T): Promise<void>;
  del(key: string): Promise<void>;
}

export const idbStore: KV = {
  get: (k) => get(k),
  set: (k, v) => set(k, v),
  del: (k) => del(k),
};

export class MemoryKV implements KV {
  readonly items = new Map<string, unknown>();
  async get<T>(k: string) {
    return this.items.get(k) as T | undefined;
  }
  async set<T>(k: string, v: T) {
    this.items.set(k, structuredClone(v));
  }
  async del(k: string) {
    this.items.delete(k);
  }
}

/** 請瀏覽器把本站資料視為「持久」，降低被系統自動清除的機會（iOS 加入主畫面後效果最好）。 */
export async function requestPersistence(): Promise<boolean | null> {
  if (typeof navigator === "undefined" || !navigator.storage?.persist) return null;
  return (await navigator.storage.persisted()) || navigator.storage.persist();
}
