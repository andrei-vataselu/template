import cors from "cors";
import express from "express";
import helmet from "helmet";
import morgan from "morgan";

const app = express();
const port = Number(process.env.PORT ?? 3000);
const environment = process.env.APP_ENV ?? "dev";
const appName = process.env.APP_NAME ?? "template";

app.disable("x-powered-by");
app.use(helmet());
app.use(morgan(process.env.NODE_ENV === "production" ? "combined" : "dev"));

// Same-origin by default (gateway proxies /api on the same domain).
// Set ALLOWED_ORIGINS="https://dxxxx.cloudfront.net,https://example.com" only
// if a browser app on a different origin must call this API.
const allowedOrigins = (process.env.ALLOWED_ORIGINS ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
if (allowedOrigins.length > 0) {
  app.use(cors({ origin: allowedOrigins, credentials: true }));
}

app.use(express.json({ limit: "100kb" }));

app.get("/api/health", (_req, res) => {
  res.json({
    ok: true,
    service: "api",
    app: appName,
    environment,
    time: new Date().toISOString(),
  });
});

app.get("/api/info", (_req, res) => {
  res.json({
    app: appName,
    environment,
    message: "Secure cost-predictable hosting stack is running on Docker.",
    stack: {
      backend: "Node.js + TypeScript + Express",
      frontend: "React + Vite + TypeScript + Tailwind",
      runtime: "Docker Compose on EC2",
    },
  });
});

app.use("/api", (_req, res) => {
  res.status(404).json({ ok: false, error: "Not found" });
});

app.listen(port, "0.0.0.0", () => {
  console.log(`[${appName}] api listening on :${port} (${environment})`);
});
