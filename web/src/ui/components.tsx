import { useState, type ReactNode } from "react";
import { parseDecimal } from "../app/book";
import { back } from "./router";

export function Page({ title, children, action, onBack }: { title: string; children: ReactNode; action?: ReactNode; onBack?: boolean }) {
  return (
    <div className="page">
      <header className="bar">
        {onBack ? <button className="link" onClick={back} aria-label="返回">‹ 返回</button> : <span />}
        <h1>{title}</h1>
        <div className="bar-action">{action}</div>
      </header>
      <main>{children}</main>
    </div>
  );
}

export function Section({ title, children, footer }: { title?: string; children: ReactNode; footer?: ReactNode }) {
  return (
    <section className="card">
      {title && <h2>{title}</h2>}
      {children}
      {footer && <p className="foot">{footer}</p>}
    </section>
  );
}

export function Row({ label, value, onClick, sub }: { label: ReactNode; value?: ReactNode; onClick?: () => void; sub?: ReactNode }) {
  const body = (
    <>
      <div className="row-main">
        <span>{label}</span>
        <span className="num">{value}</span>
      </div>
      {sub && <div className="row-sub">{sub}</div>}
    </>
  );
  return onClick ? <button className="row tap" onClick={onClick}>{body}</button> : <div className="row">{body}</div>;
}

export const Tag = ({ text, tone = "warn" }: { text: string; tone?: "warn" | "info" }) => <span className={`tag ${tone}`}>{text}</span>;

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="field">
      <span>{label}</span>
      {children}
    </label>
  );
}

export function DecimalInput({ label, value, onChange, placeholder }: { label: string; value: string; onChange: (v: string) => void; placeholder?: string }) {
  const bad = value !== "" && parseDecimal(value) === null;
  return (
    <Field label={label}>
      <input inputMode="decimal" value={value} placeholder={placeholder ?? "0"} className={bad ? "bad" : ""} onChange={(e) => onChange(e.target.value)} aria-label={label} />
    </Field>
  );
}

export function Segmented<T extends string>({ value, options, onChange, label }: { value: T; options: [T, string][]; onChange: (v: T) => void; label: string }) {
  return (
    <div className="seg" role="radiogroup" aria-label={label}>
      {options.map(([v, l]) => (
        <button key={v} role="radio" aria-checked={v === value} className={v === value ? "on" : ""} onClick={() => onChange(v)}>{l}</button>
      ))}
    </div>
  );
}

/** 4 位數密碼輸入（4 個圓點與數字鍵盤） */
export function PasscodePad({ title, subtitle, disabled, onComplete }: { title: string; subtitle?: string | null; disabled?: boolean; onComplete: (pin: string) => void }) {
  const [pin, setPin] = useState("");
  // 第 4 碼輸入後立即送出並清空，下一次輸入不會被吃掉
  const press = (k: string) => {
    if (k === "⌫") return setPin((p) => p.slice(0, -1));
    const next = pin + k;
    if (next.length < 4) return setPin(next);
    setPin("");
    onComplete(next);
  };
  const keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"];
  return (
    <div className={`pad ${disabled ? "disabled" : ""}`}>
      <h2>{title}</h2>
      {subtitle && <p className="muted center" role="status">{subtitle}</p>}
      <div className="dots" aria-label={`已輸入 ${pin.length} 位`}>
        {[0, 1, 2, 3].map((i) => <span key={i} className={i < pin.length ? "on" : ""} />)}
      </div>
      <div className="keys">
        {keys.map((k, i) =>
          k === "" ? <span key={i} /> : (
            <button key={i} disabled={disabled} aria-label={k === "⌫" ? "刪除" : k} onClick={() => press(k)}>{k}</button>
          ))}
      </div>
    </div>
  );
}
