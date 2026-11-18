// 4 位數密碼與復原碼（docs/10）。與 ios/DCAKit/Sources/DCASecurity 相同規則。
// 這個模組完全不接觸投資資料：重設密碼在結構上不可能刪除資料。
import type { KV } from "./storage";

export const STATE_KEY = "security.state.v1";
export const PRODUCTION_ITERATIONS = 600_000;
export const WIPE_TEXT = "清除全部資料";
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export type PasscodeErrorCode =
  | "NOT_FOUR_DIGITS" | "TOO_SIMPLE" | "MISMATCH" | "NOT_CONFIGURED" | "ALREADY_CONFIGURED" | "CHALLENGE_FAILED"
  | "DATA_LOSS_NOT_ACKNOWLEDGED" | "LOCKED" | "WRONG_PASSCODE" | "WRONG_RECOVERY_CODE" | "INVALID_RECOVERY_FORMAT";

export class PasscodeError extends Error {
  constructor(readonly code: PasscodeErrorCode, readonly detail = 0) {
    super(code);
  }
}

export interface LockState {
  failedCount: number;
  lockDuration: number; // 秒
  lockStartWall: number | null; // ms
  lastSeenWall: number | null;
}

export interface SecurityState {
  version: 1;
  iterations: number;
  pinSalt: string;
  pinHash: string;
  recoverySalt: string;
  recoveryHash: string;
  pinLock: LockState;
  recoveryLock: LockState;
  dataLossAcknowledgedAt: string | null;
  relockAfterSeconds: number;
}

const emptyLock = (): LockState => ({ failedCount: 0, lockDuration: 0, lockStartWall: null, lastSeenWall: null });

/** 1–4 次不鎖；第 5 次 1 分鐘、第 6 次 5 分鐘、第 7 次 15 分鐘、之後每次 1 小時。 */
export function lockDuration(n: number): number {
  if (n < 5) return 0;
  return n === 5 ? 60 : n === 6 ? 300 : n === 7 ? 900 : 3600;
}

/**
 * 剩餘鎖定秒數。瀏覽器拿不到開機後的單調時間，所以：
 * 牆上時間若比上次看到的還早（使用者把時間往回調），視為鎖定重新開始；
 * 把時間往後調可以縮短等待，這是網頁版的已知限制（iPhone 原生版用單調時間）。
 */
export function lockRemaining(s: LockState, nowMs: number): number {
  if (!s.lockDuration || s.lockStartWall === null) return 0;
  const start = s.lastSeenWall !== null && nowMs < s.lastSeenWall ? nowMs : s.lockStartWall;
  const elapsed = Math.max(0, (nowMs - start) / 1000);
  return Math.max(0, Math.ceil(s.lockDuration - elapsed));
}

function recordFailure(s: LockState, nowMs: number): LockState {
  const n = s.failedCount + 1;
  const d = lockDuration(n);
  return d ? { failedCount: n, lockDuration: d, lockStartWall: nowMs, lastSeenWall: nowMs } : { ...s, failedCount: n, lastSeenWall: nowMs };
}

const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

export async function pbkdf2(secret: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, 256);
  return new Uint8Array(bits);
}

function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export function validatePasscode(pin: string): void {
  if (!/^[0-9]{4}$/.test(pin)) throw new PasscodeError("NOT_FOUR_DIGITS");
  const d = [...pin].map(Number);
  if (new Set(d).size === 1) throw new PasscodeError("TOO_SIMPLE");
  const steps = d.slice(1).map((x, i) => x - d[i]);
  if (steps.every((s) => s === 1) || steps.every((s) => s === -1)) throw new PasscodeError("TOO_SIMPLE");
}

/** Crockford Base32：不分大小寫，O→0、I/L→1；其他字元回傳 null */
export function normalizeRecovery(input: string): string | null {
  let out = "";
  for (const ch of input.toUpperCase()) {
    if ("- \t\n".includes(ch)) continue;
    if (ch === "O") out += "0";
    else if (ch === "I" || ch === "L") out += "1";
    else if (ALPHABET.includes(ch)) out += ch;
    else return null;
  }
  return out;
}

export const recoveryGroups = (code: string) => code.match(/.{4}/g) ?? [];
export const formatRecovery = (code: string) => recoveryGroups(code).join("-");

export interface PendingCredentials {
  passcode: string;
  recoveryCode: string; // 20 字元，已正規化
  challengeGroups: number[];
}

export type RandomBytes = (n: number) => Uint8Array;
const systemRandom: RandomBytes = (n) => crypto.getRandomValues(new Uint8Array(n));

export class PasscodeManager {
  constructor(
    private readonly kv: KV,
    private readonly now: () => number = () => Date.now(),
    private readonly random: RandomBytes = systemRandom,
    private readonly iterations = PRODUCTION_ITERATIONS,
  ) {}

  async state(): Promise<SecurityState | null> {
    return (await this.kv.get<SecurityState>(STATE_KEY)) ?? null;
  }

  private async require(): Promise<SecurityState> {
    const s = await this.state();
    if (!s) throw new PasscodeError("NOT_CONFIGURED");
    return s;
  }

  private save(s: SecurityState) {
    return this.kv.set(STATE_KEY, s);
  }

  async isConfigured() {
    return (await this.state()) !== null;
  }

  private newCredentials(pin: string, confirm: string): PendingCredentials {
    validatePasscode(pin);
    if (pin !== confirm) throw new PasscodeError("MISMATCH");
    const code = [...this.random(20)].map((b) => ALPHABET[b & 31]).join("");
    const groups = new Set<number>();
    while (groups.size < 2) groups.add(this.random(1)[0] % 5);
    return { passcode: pin, recoveryCode: code, challengeGroups: [...groups].sort() };
  }

  private checkChallenge(p: PendingCredentials, answers: Record<number, string>) {
    const g = recoveryGroups(p.recoveryCode);
    for (const i of p.challengeGroups) {
      if (normalizeRecovery(answers[i] ?? "") !== g[i]) throw new PasscodeError("CHALLENGE_FAILED");
    }
  }

  private async hashFields(p: PendingCredentials) {
    const ps = this.random(16), rs = this.random(16);
    return {
      pinSalt: b64(ps), pinHash: b64(await pbkdf2(p.passcode, ps, this.iterations)),
      recoverySalt: b64(rs), recoveryHash: b64(await pbkdf2(p.recoveryCode, rs, this.iterations)),
    };
  }

  async beginSetup(pin: string, confirm: string): Promise<PendingCredentials> {
    if (await this.isConfigured()) throw new PasscodeError("ALREADY_CONFIGURED");
    return this.newCredentials(pin, confirm);
  }

  async completeSetup(p: PendingCredentials, answers: Record<number, string>, dataLossAcknowledged: boolean) {
    if (await this.isConfigured()) throw new PasscodeError("ALREADY_CONFIGURED");
    this.checkChallenge(p, answers);
    if (!dataLossAcknowledged) throw new PasscodeError("DATA_LOSS_NOT_ACKNOWLEDGED");
    await this.save({ version: 1, iterations: this.iterations, ...(await this.hashFields(p)), pinLock: emptyLock(),
                      recoveryLock: emptyLock(), dataLossAcknowledgedAt: new Date(this.now()).toISOString(), relockAfterSeconds: 60 });
  }

  async lockRemaining(): Promise<number> {
    const s = await this.state();
    return s ? lockRemaining(s.pinLock, this.now()) : 0;
  }

  async unlock(pin: string): Promise<void> {
    const s = await this.require();
    const now = this.now();
    const remaining = lockRemaining(s.pinLock, now);
    if (remaining > 0) {
      s.pinLock.lastSeenWall = Math.max(s.pinLock.lastSeenWall ?? 0, now);
      await this.save(s);
      throw new PasscodeError("LOCKED", remaining);
    }
    const cand = await pbkdf2(pin, unb64(s.pinSalt), s.iterations);
    if (constantTimeEqual(cand, unb64(s.pinHash))) {
      s.pinLock = emptyLock();
      await this.save(s);
      return;
    }
    s.pinLock = recordFailure(s.pinLock, now);
    await this.save(s);
    throw new PasscodeError("WRONG_PASSCODE", s.pinLock.failedCount);
  }

  async beginRecovery(code: string, newPin: string, confirm: string): Promise<PendingCredentials> {
    const s = await this.require();
    const now = this.now();
    const remaining = lockRemaining(s.recoveryLock, now);
    if (remaining > 0) throw new PasscodeError("LOCKED", remaining);
    const n = normalizeRecovery(code);
    if (!n || n.length !== 20) throw new PasscodeError("INVALID_RECOVERY_FORMAT");
    const cand = await pbkdf2(n, unb64(s.recoverySalt), s.iterations);
    if (!constantTimeEqual(cand, unb64(s.recoveryHash))) {
      s.recoveryLock = recordFailure(s.recoveryLock, now);
      await this.save(s);
      throw new PasscodeError("WRONG_RECOVERY_CODE", s.recoveryLock.failedCount);
    }
    s.recoveryLock = emptyLock();
    await this.save(s);
    return this.newCredentials(newPin, confirm);
  }

  /** 重設密碼與重新產生復原碼共用：舊碼作廢；投資資料完全不動。 */
  async replaceCredentials(p: PendingCredentials, answers: Record<number, string>) {
    const s = await this.require();
    this.checkChallenge(p, answers);
    await this.save({ ...s, iterations: this.iterations, ...(await this.hashFields(p)), pinLock: emptyLock(), recoveryLock: emptyLock() });
  }

  async beginRegenerate(currentPin: string): Promise<PendingCredentials> {
    await this.unlock(currentPin);
    return this.newCredentials(currentPin, currentPin);
  }

  async setRelockAfter(seconds: number) {
    const s = await this.require();
    s.relockAfterSeconds = [0, 60, 300].includes(seconds) ? seconds : 60;
    await this.save(s);
  }

  async wipe(confirmation: string): Promise<boolean> {
    if (confirmation !== WIPE_TEXT) return false;
    await this.kv.del(STATE_KEY);
    return true;
  }
}
