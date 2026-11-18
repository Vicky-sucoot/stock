import { useCallback, useEffect, useState } from "react";
import { formatRecovery, recoveryGroups, validatePasscode, WIPE_TEXT, type PendingCredentials } from "../app/security";
import { PasscodePad, Section } from "./components";
import { describeError, useApp } from "./model";

/** 顯示復原碼並要求核對其中兩組（設定、重設、重新產生共用；docs/10 §2） */
export function RecoveryConfirm({ creds, title, requireAck, onConfirm }: {
  creds: PendingCredentials; title: string; requireAck?: boolean; onConfirm: (answers: Record<number, string>) => Promise<string | null>;
}) {
  const [revealed, setRevealed] = useState(true);
  const [answers, setAnswers] = useState<Record<number, string>>({});
  const [ack, setAck] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  if (revealed) {
    return (
      <Section title={title} footer="復原碼只會顯示這一次。請抄在紙上並妥善保存，不要只存在這支手機裡。忘記 App 密碼時，需要用它重設密碼。">
        <p className="recovery" data-testid="recovery-code">{formatRecovery(creds.recoveryCode)}</p>
        <button className="primary" onClick={() => setRevealed(false)}>我已抄好，下一步</button>
      </Section>
    );
  }
  return (
    <Section title="核對復原碼" footer="請輸入你抄下的復原碼中指定的兩組。">
      {creds.challengeGroups.map((g) => (
        <label className="field" key={g}>
          <span>第 {g + 1} 組（4 個字元）</span>
          <input autoCapitalize="characters" autoCorrect="off" value={answers[g] ?? ""} aria-label={`第 ${g + 1} 組`}
            onChange={(e) => setAnswers({ ...answers, [g]: e.target.value })} />
        </label>
      ))}
      {requireAck && (
        <label className="check">
          <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} />
          <span>我了解：資料只存在這支手機的瀏覽器中，不做備份也不匯出。刪除這個網頁 App、清除 Safari 網站資料、換手機，或同時遺失密碼與復原碼時，資料無法找回。</span>
        </label>
      )}
      {msg && <p className="error">{msg}</p>}
      <button className="primary" disabled={requireAck && !ack} onClick={async () => setMsg(await onConfirm(answers))}>確認</button>
      <button className="link" onClick={() => setRevealed(true)}>再看一次復原碼</button>
    </Section>
  );
}

export function Onboarding() {
  const { passcode, run, unlocked } = useApp();
  const [step, setStep] = useState<"welcome" | "pin" | "confirm" | "recovery" | "portfolio">("welcome");
  const [first, setFirst] = useState("");
  const [creds, setCreds] = useState<PendingCredentials | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [name, setName] = useState("我的投資組合");

  const onPin = useCallback((p: string) => {
    try {
      validatePasscode(p);
      setFirst(p);
      setMsg(null);
      setStep("confirm");
    } catch (e) {
      setMsg(describeError(e));
    }
  }, []);
  const onConfirm = useCallback(async (p: string) => {
    try {
      setCreds(await passcode.beginSetup(first, p));
      setMsg(null);
      setStep("recovery");
    } catch (e) {
      setMsg(describeError(e));
      setStep("pin");
    }
  }, [first, passcode]);

  return (
    <div className="page"><main>
      {step === "welcome" && (
        <Section title="定期定額投資管理">
          <p>這個 App 用來規劃與記錄你的定期定額投資。</p>
          <ul className="bullets">
            <li>不連接券商、不下單、不會自動扣款</li>
            <li>投資資料只存在這支手機的瀏覽器中，不上傳、不備份、不匯出</li>
            <li>建議用 Safari 開啟後「分享 → 加入主畫面」，以 App 方式使用</li>
            <li>行情可能延遲；你可以隨時手動修改價格與匯率</li>
          </ul>
          <p className="muted">本 App 提供的資訊不構成投資建議，不保證準確或獲利。</p>
          <button className="primary" onClick={() => setStep("pin")}>下一步</button>
        </Section>
      )}
      {step === "pin" && <PasscodePad title="設定 4 位數 App 密碼" subtitle={msg ?? "請避免 0000、1234 這類組合"} onComplete={onPin} />}
      {step === "confirm" && <PasscodePad title="再輸入一次" subtitle={msg} onComplete={onConfirm} />}
      {step === "recovery" && creds && (
        <RecoveryConfirm creds={creds} title="你的復原碼" requireAck onConfirm={async (a) => {
          try {
            await passcode.completeSetup(creds, a, true);
            setStep("portfolio");
            return null;
          } catch (e) {
            return describeError(e);
          }
        }} />
      )}
      {step === "portfolio" && (
        <Section title="建立第一個投資組合" footer="之後可以再建立更多，例如「退休」「子女教育」。">
          <label className="field"><span>名稱</span><input value={name} onChange={(e) => setName(e.target.value)} aria-label="投資組合名稱" /></label>
          <button className="primary" onClick={async () => {
            if ((await run((b) => b.createPortfolio(name))) !== undefined) unlocked();
          }}>完成</button>
        </Section>
      )}
    </main></div>
  );
}

export function LockScreen() {
  const { passcode, unlocked } = useApp();
  const [msg, setMsg] = useState<string | null>(null);
  const [locked, setLocked] = useState(0);
  const [busy, setBusy] = useState(false);
  const [recover, setRecover] = useState(false);

  useEffect(() => {
    passcode.lockRemaining().then(setLocked);
    const t = setInterval(() => passcode.lockRemaining().then(setLocked), 1000);
    return () => clearInterval(t);
  }, [passcode]);

  const onPin = useCallback(async (p: string) => {
    setBusy(true);
    try {
      await passcode.unlock(p);
      unlocked();
    } catch (e) {
      setMsg(describeError(e));
      setLocked(await passcode.lockRemaining());
    } finally {
      setBusy(false);
    }
  }, [passcode, unlocked]);

  if (recover) return <RecoveryReset onCancel={() => setRecover(false)} />;
  return (
    <div className="page"><main className="lock">
      <PasscodePad title="輸入 App 密碼" subtitle={locked > 0 ? `請於 ${locked} 秒後再試` : msg} disabled={busy || locked > 0} onComplete={onPin} />
      <button className="link" onClick={() => setRecover(true)}>忘記密碼？使用復原碼</button>
    </main></div>
  );
}

/** 用復原碼重設密碼：投資資料完全不動，並產生新的復原碼（docs/10 §5） */
function RecoveryReset({ onCancel }: { onCancel: () => void }) {
  const { passcode, unlocked } = useApp();
  const [code, setCode] = useState("");
  const [p1, setP1] = useState("");
  const [p2, setP2] = useState("");
  const [creds, setCreds] = useState<PendingCredentials | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  return (
    <div className="page"><main>
      {creds ? (
        <RecoveryConfirm creds={creds} title="新的復原碼" onConfirm={async (a) => {
          try {
            await passcode.replaceCredentials(creds, a);
            unlocked();
            return null;
          } catch (e) {
            return describeError(e);
          }
        }} />
      ) : (
        <Section title="重設密碼" footer="重設密碼不會刪除或變更任何投資資料。完成後會產生新的復原碼，舊的復原碼立即失效。">
          <label className="field"><span>復原碼</span><input value={code} autoCapitalize="characters" autoCorrect="off" placeholder="例如 7K3M-QX9P-2HVD-R8TN-W4CJ" onChange={(e) => setCode(e.target.value)} aria-label="復原碼" /></label>
          <label className="field"><span>新的 4 位數密碼</span><input type="password" inputMode="numeric" value={p1} onChange={(e) => setP1(e.target.value)} aria-label="新密碼" /></label>
          <label className="field"><span>再輸入一次</span><input type="password" inputMode="numeric" value={p2} onChange={(e) => setP2(e.target.value)} aria-label="再輸入新密碼" /></label>
          {msg && <p className="error">{msg}</p>}
          <button className="primary" disabled={busy || !code || p1.length !== 4} onClick={async () => {
            setBusy(true);
            try {
              setCreds(await passcode.beginRecovery(code, p1, p2));
            } catch (e) {
              setMsg(describeError(e));
            } finally {
              setBusy(false);
            }
          }}>{busy ? "驗證中…" : "驗證並繼續"}</button>
          <button className="link" onClick={onCancel}>取消</button>
        </Section>
      )}
    </main></div>
  );
}

export function RegenerateRecovery({ onDone }: { onDone: () => void }) {
  const { passcode } = useApp();
  const [creds, setCreds] = useState<PendingCredentials | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const onPin = useCallback(async (p: string) => {
    try {
      setCreds(await passcode.beginRegenerate(p));
    } catch (e) {
      setMsg(describeError(e));
    }
  }, [passcode]);
  if (!creds) return <PasscodePad title="輸入目前的 App 密碼" subtitle={msg ?? "完成後舊的復原碼會立即失效"} onComplete={onPin} />;
  return (
    <RecoveryConfirm creds={creds} title="新的復原碼" onConfirm={async (a) => {
      try {
        await passcode.replaceCredentials(creds, a);
        onDone();
        return null;
      } catch (e) {
        return describeError(e);
      }
    }} />
  );
}

export { WIPE_TEXT, recoveryGroups };
