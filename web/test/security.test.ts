import { describe, expect, it } from "vitest";
import { MemoryKV } from "../src/app/storage";
import { formatRecovery, lockDuration, lockRemaining, normalizeRecovery, PasscodeError, PasscodeManager, pbkdf2, recoveryGroups, STATE_KEY, validatePasscode, type PendingCredentials } from "../src/app/security";

const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");

function splitmix(seed = 0x12345678n) {
  let s = seed;
  const M = (1n << 64n) - 1n;
  return (n: number) => Uint8Array.from({ length: n }, () => {
    s = (s + 0x9e3779b97f4a7c15n) & M;
    let z = s;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & M;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & M;
    return Number((z ^ (z >> 31n)) & 255n);
  });
}

async function code(e: Promise<unknown>) {
  try {
    await e;
  } catch (err) {
    return [(err as PasscodeError).code, (err as PasscodeError).detail];
  }
  return null;
}

const answers = (p: PendingCredentials) => Object.fromEntries(p.challengeGroups.map((g) => [g, recoveryGroups(p.recoveryCode)[g].toLowerCase()]));

function setup() {
  const kv = new MemoryKV();
  let now = 1_800_000_000_000;
  const clock = { advance: (s: number) => (now += s * 1000), set: (ms: number) => (now = ms), get: () => now };
  const mgr = new PasscodeManager(kv, () => now, splitmix(), 1000);
  return { kv, mgr, clock };
}

describe("pbkdf2 (WebCrypto)", () => {
  it("matches Python hashlib reference vectors", async () => {
    const salt = new TextEncoder().encode("salt");
    expect(hex(await pbkdf2("password", salt, 1))).toBe("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
    expect(hex(await pbkdf2("password", salt, 4096))).toBe("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");
  });
});

describe("rules", () => {
  it("passcode validation", () => {
    for (const bad of ["123", "12345", "12a4"]) expect(() => validatePasscode(bad)).toThrow("NOT_FOUR_DIGITS");
    for (const weak of ["0000", "1234", "9876"]) expect(() => validatePasscode(weak)).toThrow("TOO_SIMPLE");
    expect(() => validatePasscode("2580")).not.toThrow();
  });
  it("recovery code normalization", () => {
    expect(normalizeRecovery("ab-cd o i l")).toBe("ABCD011");
    expect(normalizeRecovery("ABCU")).toBeNull();
    expect(formatRecovery("ABCDEFGHJKMNPQRSTVWX")).toBe("ABCD-EFGH-JKMN-PQRS-TVWX");
  });
  it("lock durations and clock rollback", () => {
    expect([1, 2, 3, 4, 5, 6, 7, 8].map(lockDuration)).toEqual([0, 0, 0, 0, 60, 300, 900, 3600]);
    const s = { failedCount: 5, lockDuration: 60, lockStartWall: 1000_000, lastSeenWall: 1000_000 };
    expect(lockRemaining(s, 1000_000 + 30_000)).toBe(30);
    expect(lockRemaining(s, 1000_000 - 3600_000)).toBe(60); // 時間往回調：重新開始
  });
});

describe("PasscodeManager", () => {
  it("setup requires challenge and acknowledgement; secrets not stored in plaintext", async () => {
    const { mgr, kv } = setup();
    expect(await code(mgr.beginSetup("2580", "2581"))).toEqual(["MISMATCH", 0]);
    const p = await mgr.beginSetup("2580", "2580");
    expect(p.challengeGroups).toHaveLength(2);
    expect(await code(mgr.completeSetup(p, {}, true))).toEqual(["CHALLENGE_FAILED", 0]);
    expect(await code(mgr.completeSetup(p, answers(p), false))).toEqual(["DATA_LOSS_NOT_ACKNOWLEDGED", 0]);
    expect(await mgr.isConfigured()).toBe(false);
    await mgr.completeSetup(p, answers(p), true);
    const blob = JSON.stringify(kv.items.get(STATE_KEY));
    expect(blob).not.toContain(p.recoveryCode);
    expect(blob).not.toContain("2580");
  });

  it("lockout after 5 failures, no data wipe", async () => {
    const { mgr, clock } = setup();
    const p = await mgr.beginSetup("2580", "2580");
    await mgr.completeSetup(p, answers(p), true);
    for (let i = 1; i <= 5; i++) expect(await code(mgr.unlock("1111"))).toEqual(["WRONG_PASSCODE", i]);
    expect(await code(mgr.unlock("2580"))).toEqual(["LOCKED", 60]);
    clock.advance(60);
    await mgr.unlock("2580");
  });

  it("recovery resets passcode and rotates code", async () => {
    const { mgr } = setup();
    const orig = await mgr.beginSetup("2580", "2580");
    await mgr.completeSetup(orig, answers(orig), true);
    expect(await code(mgr.beginRecovery("0000-0000-0000-0000-0000", "1357", "1357"))).toEqual(["WRONG_RECOVERY_CODE", 1]);
    const p = await mgr.beginRecovery(formatRecovery(orig.recoveryCode).toLowerCase(), "1357", "1357");
    expect(p.recoveryCode).not.toBe(orig.recoveryCode);
    await mgr.replaceCredentials(p, answers(p));
    await mgr.unlock("1357");
    expect(await code(mgr.unlock("2580"))).toEqual(["WRONG_PASSCODE", 1]);
    expect(await code(mgr.beginRecovery(orig.recoveryCode, "2468", "2468"))).toEqual(["WRONG_RECOVERY_CODE", 1]);
  });

  it("wipe needs exact text", async () => {
    const { mgr } = setup();
    const p = await mgr.beginSetup("2580", "2580");
    await mgr.completeSetup(p, answers(p), true);
    expect(await mgr.wipe("清除")).toBe(false);
    expect(await mgr.wipe("清除全部資料")).toBe(true);
    expect(await mgr.isConfigured()).toBe(false);
  });
});
