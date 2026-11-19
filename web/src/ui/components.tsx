import type { ReactNode } from "react";
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
