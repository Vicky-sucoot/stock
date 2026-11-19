import { useState } from "react";
import { Section } from "./components";
import { useApp } from "./model";

/** 首次使用：說明 → 勾選資料保存說明 → 建立第一個投資組合（不設定密碼，依使用者決定） */
export function Onboarding() {
  const { completeOnboarding } = useApp();
  const [ack, setAck] = useState(false);
  const [name, setName] = useState("我的投資組合");
  return (
    <div className="page"><main>
      <Section title="定期定額投資管理">
        <p>這個 App 用來規劃與記錄你的定期定額投資。</p>
        <ul className="bullets">
          <li>不連接券商、不下單、不會自動扣款</li>
          <li>投資資料只存在這支手機的瀏覽器中，不上傳、不備份、不匯出</li>
          <li>開啟 App 不需要密碼；請自行保管好手機</li>
          <li>建議用 Safari 開啟後「分享 → 加入主畫面」，以 App 方式使用</li>
          <li>行情可能延遲；你可以隨時手動修改價格與匯率</li>
        </ul>
        <p className="muted">本 App 提供的資訊不構成投資建議，不保證準確或獲利。</p>
        <label className="check">
          <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} aria-label="資料保存說明" />
          <span>我了解：資料只存在這支手機的瀏覽器中，不做備份也不匯出。刪除這個網頁 App、清除 Safari 網站資料或換手機時，資料無法找回。</span>
        </label>
      </Section>
      <Section title="建立第一個投資組合" footer="之後可以再建立更多，例如「退休」「子女教育」。">
        <label className="field"><span>名稱</span><input value={name} onChange={(e) => setName(e.target.value)} aria-label="投資組合名稱" /></label>
        <button className="primary" disabled={!ack} onClick={() => completeOnboarding(name)}>開始使用</button>
      </Section>
    </main></div>
  );
}
