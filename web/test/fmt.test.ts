import { describe, expect, it } from "vitest";
import { D } from "../src/core/decimal";
import { money, pct, qty, signedMoney } from "../src/ui/fmt";

describe("formatting", () => {
  it("money puts the sign before the currency symbol", () => {
    expect(money(D("-200"), "TWD")).toBe("-NT$200");
    expect(signedMoney(D("200"), "TWD")).toBe("+NT$200");
    expect(money(D("1234567.891"), "USD")).toBe("US$1,234,567.89");
    expect(money(D("-0.001"), "USD")).toBe("US$0.00");
    expect(money(null, "TWD")).toBe("—");
  });
  it("percent and quantity", () => {
    expect(pct(D("-0.0662251656"))).toBe("-6.62%");
    expect(qty(D("0.1234567"))).toBe("0.123457");
  });
});
