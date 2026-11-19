// 端對端測試：在 Chromium 以 iPhone 尺寸操作完整流程（需先 npm run build，並在 dist/data 放 quotes.json
// 與 watchlist.enc.json；後者可用 backend 測試資料產生，密語 "correct horse battery"）。
//   node e2e/run.mjs [截圖目錄]
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";

const require = createRequire(import.meta.url);
const { chromium, devices } = require("playwright");
const shots = process.argv[2] ?? "test-results";
mkdirSync(shots, { recursive: true });

const server = spawn("npx", ["vite", "preview", "--port", "4173", "--strictPort"], { stdio: "pipe", detached: true });
const stopServer = () => { try { process.kill(-server.pid, "SIGTERM"); } catch { /* 已結束 */ } };
await new Promise((ok, fail) => {
  server.stdout.on("data", (d) => String(d).includes("4173") && ok());
  server.on("exit", () => fail(new Error("preview server exited (port 4173 in use?)")));
  setTimeout(() => fail(new Error("preview timeout")), 30000);
});

const URL = "http://localhost:4173/";
let failures = 0;
const check = (cond, msg) => {
  console.log(`${cond ? "PASS" : "FAIL"} ${msg}`);
  if (!cond) failures++;
};

const browser = await chromium.launch();
const ctx = await browser.newContext({ ...devices["iPhone 13"], locale: "zh-TW", timezoneId: "Asia/Taipei" });
const page = await ctx.newPage();
page.on("pageerror", (e) => { console.log("PAGE ERROR", e.message); failures++; });
const pin = async (p) => { for (const d of p) await page.getByRole("button", { name: d, exact: true }).click(); };
const shot = (n) => page.screenshot({ path: `${shots}/${n}.png`, fullPage: true });

try {
  await page.goto(URL);
  // --- 首次使用：不設定密碼；必須勾選資料保存說明 ---
  const start = page.getByRole("button", { name: "開始使用" });
  await start.waitFor();
  const setupText = await page.locator("main").innerText();
  check(!/設定.*密碼|復原碼|Face ID/.test(setupText) && setupText.includes("開啟 App 不需要密碼"),
        "onboarding has no passcode setup, recovery code or Face ID");
  check(await start.isDisabled(), "start disabled until data-loss acknowledged");
  await page.getByLabel("資料保存說明").check();
  await page.getByLabel("投資組合名稱").fill("長期投資");
  await start.click();
  await page.getByText("總覽", { exact: true }).waitFor();
  await shot("01-home-empty");
  check(await page.getByText("目前沒有待確認的期數").isVisible(), "home shows plan card first");

  // --- 新增定期定額（補產生） ---
  await page.getByText("長期投資").first().click();
  await page.getByRole("radio", { name: "計畫" }).click();
  await page.getByRole("button", { name: "＋ 新增定期定額計畫", exact: true }).click();
  await page.getByRole("button", { name: /^選擇標的/ }).click();
  await page.getByLabel("搜尋標的").fill("0050");
  await page.getByText("0050 元大台灣50").click();
  await page.getByLabel("金額（TWD）").fill("3000");
  await page.getByLabel("每月日期").fill("31");
  await page.getByLabel("開始日").fill("2026-09-01");
  await page.getByText("接下來 6 期").waitFor();
  await shot("03-plan-preview");
  await page.getByRole("button", { name: "儲存" }).click();
  await page.getByRole("button", { name: "補產生", exact: true }).click();
  await page.getByRole("button", { name: "首頁" }).click();
  const pendingText = await page.getByText(/筆待確認/).textContent();
  check(pendingText.includes("2 筆待確認"), `pending generated: ${pendingText}`);
  await shot("04-home-pending");

  // --- 確認一期 ---
  await page.getByText(/筆待確認/).click();
  await page.getByRole("button", { name: "確認" }).first().click();
  await page.getByLabel("成交價格").fill("100");
  await page.getByLabel(/^數量/).fill("30");
  await page.getByLabel("手續費").fill("20");
  await page.getByRole("button", { name: "確認" }).click();
  await page.getByText("1 筆待確認").or(page.getByText("待確認")).first().waitFor();
  await page.getByRole("button", { name: "首頁" }).click();
  const total = await page.getByTestId("total-assets").textContent();
  // 30 單位 × 0050 官方收盤價（quotes.json：94.00）= 2,820
  check(total === "NT$2,820", `total assets uses official close (expect NT$2,820): ${total}`);
  check(await page.getByText(/資料來源：臺灣證券交易所 OpenAPI/).first().isVisible(), "attribution shown on home");
  await shot("05-home-after-confirm");

  // --- 手動匯率 ---
  await page.getByText("USD/TWD").click();
  await page.getByLabel("1 USD = ? TWD").fill("32.1");
  await page.getByRole("button", { name: "儲存" }).click();
  check(await page.getByText("32.100").first().waitFor().then(() => true, () => false), "manual fx 32.100 shown on home after save");

  // --- 美元檢視 ---
  await page.getByRole("radio", { name: "美元 USD" }).click();
  const usd = await page.getByTestId("total-assets").textContent();
  check(usd.startsWith("US$"), `USD view: ${usd}`);
  await page.getByRole("radio", { name: "台幣 TWD" }).click();

  // --- 重新開啟：直接進入首頁，不需要密碼；資料保留 ---
  await page.reload();
  await page.getByTestId("total-assets").waitFor();
  check((await page.getByTestId("total-assets").textContent()) === total, "reopen goes straight to home with data intact");
  check(!(await page.getByText(/輸入 App 密碼/).count()), "no lock screen after reload");
  await shot("06-home-final");

  // --- 每日名單：輸入通關密語解密（dist/data/watchlist.enc.json，密語 "correct horse battery"） ---
  await page.getByRole("button", { name: "名單", exact: true }).click();
  await page.getByLabel("通關密語").fill("wrong passphrase");
  await page.getByRole("button", { name: "解鎖名單" }).click();
  check(await page.getByText("通關密語不正確").waitFor().then(() => true, () => false), "wrong passphrase rejected");
  await page.getByLabel("通關密語").fill("correct horse battery");
  await page.getByRole("button", { name: "解鎖名單" }).click();
  await page.getByText(/^建議買入（/).waitFor();
  const wtext = await page.locator("main").innerText();
  check(/建議賣出／避開（/.test(wtext) && /訊號衝突／資料不足（/.test(wtext) && wtext.includes("不構成投資建議"),
        "list labels and disclaimer shown");
  await shot("07-watchlist");
  await page.getByText(/^A001 /).first().click();
  await page.getByText("外資及陸資買賣超（不含自營商）").waitFor();
  check(await page.getByText("官方來源").isVisible(), "detail shows official source link");
  await shot("08-watch-detail");
  await page.reload();
  await page.getByText("外資及陸資買賣超（不含自營商）").waitFor();
  check(!(await page.getByLabel("通關密語").count()), "passphrase remembered on this phone after reload");
  const dtext = await page.locator("main").innerText();
  check(dtext.includes("Claude") && dtext.includes("規則分"), "detail shows Claude score with rule cross-check");

  // --- 刪除組合需輸入正確名稱 ---
  await page.getByRole("button", { name: "組合", exact: true }).click();
  await page.getByRole("button", { name: /長期投資/ }).click();
  await page.getByRole("button", { name: "刪除組合" }).click();
  await page.getByLabel("刪除確認名稱").fill("錯誤名稱");
  await page.getByRole("button", { name: "確認刪除" }).click();
  check(await page.getByText("名稱不符，未刪除任何資料").isVisible(), "wrong name does not delete");
  await page.getByRole("button", { name: "好" }).click();

  // --- 清除全部資料後回到首次使用 ---
  await page.getByRole("button", { name: "設定", exact: true }).click();
  await page.getByRole("button", { name: "清除所有資料並重新開始" }).click();
  await page.getByLabel("清除確認文字").fill("清除全部資料");
  await page.getByRole("button", { name: "清除", exact: true }).click();
  await page.getByRole("button", { name: "開始使用" }).waitFor();
  check(true, "wipe returns to onboarding");

  // --- 版面：沒有水平捲動 ---
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
  check(!overflow, "no horizontal scroll at iPhone width");
} catch (e) {
  console.log("FAIL exception:", e.message);
  await shot("99-failure");
  failures++;
} finally {
  await browser.close();
  stopServer();
}
console.log(failures ? `\n${failures} failure(s)` : "\nALL PASSED");
process.exit(failures ? 1 : 0);
