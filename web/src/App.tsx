import { Home, FxHelp } from "./ui/home";
import { useApp } from "./ui/model";
import { PortfolioDetail, PortfolioEdit, PortfolioList } from "./ui/portfolio";
import { ConfirmOccurrence, PendingList, PlanEdit } from "./ui/plan";
import { go, useRoute } from "./ui/router";
import { Onboarding } from "./ui/onboarding";
import { ManualValue, Settings, Sources, WatchPlaceholder } from "./ui/settings";
import { InstrumentDetail, TxEdit } from "./ui/tx";

function Screen({ r }: { r: string[] }) {
  switch (r[0]) {
    case "pending": return <PendingList />;
    case "confirm": return <ConfirmOccurrence id={r[1]} />;
    case "portfolios": return <PortfolioList />;
    case "portfolio": return <PortfolioDetail id={r[1]} />;
    case "portfolio-new": return <PortfolioEdit />;
    case "portfolio-edit": return <PortfolioEdit id={r[1]} />;
    case "plan": return <PlanEdit portfolioId={r[1]} id={r[2]} />;
    case "tx-new": return <TxEdit portfolioId={r[1]} />;
    case "tx": return <TxEdit portfolioId={r[1]} id={r[2]} />;
    case "instrument": return <InstrumentDetail portfolioId={r[1]} id={r[2]} />;
    case "manual": return <ManualValue kind={r[1] as "price" | "fx"} id={r[2]} />;
    case "fx-help": return <FxHelp />;
    case "settings": return <Settings />;
    case "sources": return <Sources />;
    case "watch": return <WatchPlaceholder />;
    default: return <Home />;
  }
}

const TABS: [string, string, string[]][] = [
  ["home", "首頁", ["home", "pending", "confirm", "fx-help", "manual"]],
  ["portfolios", "組合", ["portfolios", "portfolio", "portfolio-new", "portfolio-edit", "plan", "tx-new", "tx", "instrument"]],
  ["watch", "觀察", ["watch"]],
  ["settings", "設定", ["settings", "sources"]],
];

export default function App() {
  const { phase, error, setError } = useApp();
  const r = useRoute();
  return (
    <>
      {phase === "loading" && <div className="page"><main><p className="muted center">載入中…</p></main></div>}
      {phase === "onboarding" && <Onboarding />}
      {phase === "ready" && (
        <>
          <Screen r={r} />
          <nav className="tabs">
            {TABS.map(([k, label, prefixes]) => (
              <button key={k} className={prefixes.includes(r[0]) ? "on" : ""} onClick={() => go(k)}>{label}</button>
            ))}
          </nav>
        </>
      )}
      {error && (
        <div className="alert" role="alertdialog" aria-label="無法完成">
          <div>
            <h2>無法完成</h2>
            <p>{error}</p>
            <button className="primary" onClick={() => setError(null)}>好</button>
          </div>
        </div>
      )}
    </>
  );
}
