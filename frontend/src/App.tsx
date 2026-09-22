import { useState, FormEvent } from "react";

type ScoreResponse = {
  score: number;
  risk_band: "low" | "medium" | "high";
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
      <h1>Risk Scoring</h1>
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
          {loading ? "Scoring..." : "Get score"}
        </button>
      </form>

      {result && (
        <div className={`result ${result.risk_band}`}>
          Score: <strong>{result.score}</strong> — Risk band: <strong>{result.risk_band}</strong>
        </div>
      )}
      {error && <div className="error">{error}</div>}
    </div>
  );
}
