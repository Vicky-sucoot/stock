import { describe, expect, it } from "vitest";
import fixture from "./watchlist.fixture.json";
import { byList, decryptWatchlist, isBlob, WrongPassphrase } from "../src/app/watchlist";

// fixture 由後端 dca_backend.watchlist.publish.encrypt 產生（密語 "correct horse battery"）
describe("watchlist decryption (Python ↔ WebCrypto)", () => {
  it("decrypts a backend-encrypted file", async () => {
    expect(isBlob(fixture)).toBe(true);
    const w = await decryptWatchlist(fixture as never, "correct horse battery");
    expect(w.data_date).toBe("2026-11-18");
    expect(byList(w).BULLISH[0].symbol).toBe("A001");
  });
  it("rejects a wrong passphrase", async () => {
    await expect(decryptWatchlist(fixture as never, "wrong passphrase")).rejects.toBeInstanceOf(WrongPassphrase);
  });
});
