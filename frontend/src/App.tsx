import { useState, FormEvent } from "react";
import ScoreGauge, { RiskBand } from "./ScoreGauge";

type ScoreResponse = {
  score: number;
  risk_band: RiskBand;
};

export default function App() {
  const [creditUtilization, setCreditUtilization] = useState("0.3");
  const [paymentHistoryScore, setPaymentHistoryScore] = useState("90");
  const [debtToIncome, setDebtToIncome] = useState("0.25");
  const [result, setResult] = useState<ScoreResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);
    setResult(null);
    try {
      const res = await fetch("/score", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          credit_utilization: Number(creditUtilization),
          payment_history_score: Number(paymentHistoryScore),
          debt_to_income: Number(debtToIncome),
        }),
      });
      if (!res.ok) {
        throw new Error(`Request failed: ${res.status}`);
      }
      setResult(await res.json());
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="card">
      <header className="header">
        <span className="header-icon" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 3l7 3v5c0 4.5-3 8.3-7 10-4-1.7-7-5.5-7-10V6l7-3z" strokeLinejoin="round" />
            <path d="M9 12l2 2 4-4" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </span>
        <div>
          <h1>Risk Scoring</h1>
          <p className="subtitle">Credit risk assessment</p>
        </div>
      </header>

      <div className="info">
        Scores run from <strong>300</strong> to <strong>850</strong>. Lower credit utilization
        and debt-to-income raise the score; stronger payment history raises it further.
      </div>

      <form onSubmit={handleSubmit}>
        <label htmlFor="credit_utilization">Credit utilization (0.0 - 1.0)</label>
        <input
          id="credit_utilization"
          type="number"
          step="0.01"
          min="0"
          max="1"
          value={creditUtilization}
          onChange={(e) => setCreditUtilization(e.target.value)}
          required
        />

        <label htmlFor="payment_history_score">Payment history score (0 - 100)</label>
        <input
          id="payment_history_score"
          type="number"
          step="1"
          min="0"
          max="100"
          value={paymentHistoryScore}
          onChange={(e) => setPaymentHistoryScore(e.target.value)}
          required
        />

        <label htmlFor="debt_to_income">Debt to income (0.0 - 1.0)</label>
        <input
          id="debt_to_income"
          type="number"
          step="0.01"
          min="0"
          max="1"
          value={debtToIncome}
          onChange={(e) => setDebtToIncome(e.target.value)}
          required
        />

        <button type="submit" disabled={loading}>
          {loading ? (
            <>
              <svg className="spinner" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                <path d="M21 12a9 9 0 11-6.2-8.6" strokeLinecap="round" />
              </svg>
              Scoring...
            </>
          ) : (
            "Get score"
          )}
        </button>
      </form>

      {result && (
        <div className={`result ${result.risk_band}`} aria-live="polite">
          <ScoreGauge score={result.score} band={result.risk_band} />
        </div>
      )}

      {error && (
        <div className="error" role="alert">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
            <circle cx="12" cy="12" r="9" />
            <path d="M12 7v6" strokeLinecap="round" />
            <circle cx="12" cy="16.5" r="1" fill="currentColor" stroke="none" />
          </svg>
          <span>{error}</span>
        </div>
      )}
    </div>
  );
}
