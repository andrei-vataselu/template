import { useEffect, useState } from "react";

type Health = {
  ok: boolean;
  app: string;
  environment: string;
  time: string;
};

type Info = {
  message: string;
  stack: Record<string, string>;
};

export default function App() {
  const [health, setHealth] = useState<Health | null>(null);
  const [info, setInfo] = useState<Info | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      try {
        const [healthRes, infoRes] = await Promise.all([
          fetch("/api/health"),
          fetch("/api/info"),
        ]);
        if (!healthRes.ok || !infoRes.ok) {
          throw new Error("API request failed");
        }
        const healthJson = (await healthRes.json()) as Health;
        const infoJson = (await infoRes.json()) as Info;
        if (!cancelled) {
          setHealth(healthJson);
          setInfo(infoJson);
          setError(null);
        }
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : "Failed to reach API");
        }
      }
    }

    void load();
    const id = window.setInterval(() => void load(), 15000);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, []);

  return (
    <div className="page">
      <div className="glow" aria-hidden />
      <header className="nav">
        <p className="brand">template</p>
        <p className="env-pill">{health?.environment ?? "…"}</p>
      </header>

      <main className="hero">
        <h1>Running on Docker — FE deploy probe</h1>
        <p className="lede">
          React + Vite frontend talking to a Node TypeScript API, fronted by
          Nginx on EC2 behind CloudFront.
        </p>

        <section className="panel">
          <h2>API status</h2>
          {error ? (
            <p className="error">{error}</p>
          ) : health ? (
            <ul>
              <li>
                <span>App</span>
                <strong>{health.app}</strong>
              </li>
              <li>
                <span>Environment</span>
                <strong>{health.environment}</strong>
              </li>
              <li>
                <span>Health</span>
                <strong className="ok">{health.ok ? "ok" : "down"}</strong>
              </li>
              <li>
                <span>Checked</span>
                <strong>{new Date(health.time).toLocaleString()}</strong>
              </li>
            </ul>
          ) : (
            <p className="muted">Checking API…</p>
          )}
        </section>

        {info ? (
          <section className="panel secondary">
            <h2>Stack</h2>
            <p>{info.message}</p>
            <ul>
              {Object.entries(info.stack).map(([key, value]) => (
                <li key={key}>
                  <span>{key}</span>
                  <strong>{value}</strong>
                </li>
              ))}
            </ul>
          </section>
        ) : null}
      </main>
    </div>
  );
}
