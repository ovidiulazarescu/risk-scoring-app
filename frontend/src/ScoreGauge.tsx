export type RiskBand = "low" | "medium" | "high";

// Mirrors the clamp in backend/app/main.py; the arc is meaningless if these drift apart.
const MIN_SCORE = 300;
const MAX_SCORE = 850;

const BAND_LABEL: Record<RiskBand, string> = {
  low: "Low risk",
  medium: "Medium risk",
  high: "High risk",
};

export default function ScoreGauge({ score, band }: { score: number; band: RiskBand }) {
  const fraction = Math.min(1, Math.max(0, (score - MIN_SCORE) / (MAX_SCORE - MIN_SCORE)));

  return (
    <div className="gauge-wrap">
      <svg
        className="gauge"
        viewBox="0 0 200 116"
        role="img"
        aria-label={`Score ${score} out of ${MAX_SCORE}. ${BAND_LABEL[band]}.`}
      >
        <path className="gauge-track" d="M 20 100 A 80 80 0 0 1 180 100" />
        <path
          className={`gauge-fill ${band}`}
          d="M 20 100 A 80 80 0 0 1 180 100"
          pathLength={100}
          strokeDasharray={`${fraction * 100} 100`}
        />
        <text className="gauge-score" x="100" y="86">
          {score}
        </text>
      </svg>
      <div className="gauge-scale">
        <span>{MIN_SCORE}</span>
        <span>{MAX_SCORE}</span>
      </div>
      <span className={`band ${band}`}>{BAND_LABEL[band]}</span>
    </div>
  );
}
