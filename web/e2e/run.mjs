// 端對端測試：在 Chromium 以 iPhone 尺寸操作完整流程（需先 npm run build，並在 dist/data 放 quotes.json）。
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
  // --- 首次設定 ---
  await page.getByRole("button", { name: "下一步", exact: true }).click();
  await pin("1234");
  check(await page.getByText("密碼太簡單").waitFor().then(() => true, () => false), "rejects weak passcode 1234");
  await pin("2580");
  await pin("2580");
  const code = (await page.getByTestId("recovery-code").textContent()).trim();
  check(/^[0-9A-Z]{4}(-[0-9A-Z]{4}){4}$/.test(code), `recovery code shown: ${code}`);
  await shot("01-recovery-code");
  await page.getByRole("button", { name: "我已抄好，下一步", exact: true }).click();
  const groups = code.split("-");
  for (const box of await page.getByLabel(/第 \d 組/).all()) {
    const n = Number((await box.getAttribute("aria-label")).match(/\d/)[0]);
    await box.fill(groups[n - 1].toLowerCase());
  }
  const confirmBtn = page.getByRole("button", { name: "確認", exact: true });
  check(await confirmBtn.isDisabled(), "confirm disabled until data-loss acknowledged");
  await page.getByRole("checkbox").check();
  await confirmBtn.click();
  await page.getByLabel("投資組合名稱").fill("長期投資");
  await page.getByRole("button", { name: "完成", exact: true }).click();
  await page.getByText("總覽", { exact: true }).waitFor();
  await shot("02-home-empty");
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

  // --- 重新開啟需解鎖；錯誤密碼 ---
  await page.reload();
  await page.getByText("輸入 App 密碼").waitFor();
  await pin("1111");
  await page.getByText("密碼錯誤").waitFor();
  check(true, "wrong passcode rejected");
  await pin("2580");
  await page.getByTestId("total-assets").waitFor();
  check((await page.getByTestId("total-assets").textContent()) === total, "data persisted across reload");

  // --- 用復原碼重設密碼，資料不變 ---
  await page.reload();
  await page.getByText("忘記密碼？使用復原碼").click();
  await page.getByLabel("復原碼").fill(code.toLowerCase());
  await page.getByLabel("新密碼", { exact: true }).fill("1357");
  await page.getByLabel("再輸入新密碼").fill("1357");
  await page.getByRole("button", { name: "驗證並繼續", exact: true }).click();
  const newCode = (await page.getByTestId("recovery-code").textContent()).trim();
  check(newCode !== code, "new recovery code generated");
  await page.getByRole("button", { name: "我已抄好，下一步", exact: true }).click();
  const g2 = newCode.split("-");
  for (const box of await page.getByLabel(/第 \d 組/).all()) {
    const n = Number((await box.getAttribute("aria-label")).match(/\d/)[0]);
    await box.fill(g2[n - 1]);
  }
  await page.getByRole("button", { name: "確認", exact: true }).click();
  await page.getByTestId("total-assets").waitFor();
  check((await page.getByTestId("total-assets").textContent()) === total, "investment data intact after passcode reset");
  await page.reload();
  await pin("1357");
  await page.getByTestId("total-assets").waitFor();
  check(true, "new passcode works");
  await shot("06-home-final");

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
