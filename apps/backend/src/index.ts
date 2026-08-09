import cors from "cors";
import express from "express";
import rateLimit from "express-rate-limit";
import helmet from "helmet";
import morgan from "morgan";
import { ZodError } from "zod";
import { config } from "./config.js";
import { initIdentityStore } from "./db/client.js";
import { adminUsersRouter } from "./routes/adminUsers.js";
import { meRouter } from "./routes/me.js";

async function main(): Promise<void> {
  await initIdentityStore();

  const app = express();

  app.disable("x-powered-by");
  app.set("trust proxy", 1);

  app.use(
    helmet({
      contentSecurityPolicy: false,
      crossOriginResourcePolicy: { policy: "same-origin" },
      hsts: config.nodeEnv === "production" ? { maxAge: 31536000, includeSubDomains: true } : false,
    }),
  );
  app.use(morgan(config.nodeEnv === "production" ? "combined" : "dev"));

  if (config.allowedOrigins.length > 0) {
    app.use(
      cors({
        origin: config.allowedOrigins,
        credentials: true,
        methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allowedHeaders: ["Authorization", "Content-Type"],
        maxAge: 600,
      }),
    );
  }

  app.use(express.json({ limit: "100kb" }));

  const apiLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 300,
    standardHeaders: true,
    legacyHeaders: false,
    message: { ok: false, error: "Too many requests", code: "rate_limited" },
  });
  app.use("/api", apiLimiter);

  const inviteLimiter = rateLimit({
    windowMs: 60 * 60 * 1000,
    max: 30,
    standardHeaders: true,
    legacyHeaders: false,
    message: { ok: false, error: "Too many invite attempts", code: "rate_limited" },
  });
  app.use("/api/admin/users", inviteLimiter);

  app.get("/api/health", (_req, res) => {
    res.json({
      ok: true,
      service: "api",
      app: config.appName,
      environment: config.environment,
      authConfigured: config.cognito.configured,
      directory: config.databaseUrl ? "postgres" : "memory",
      time: new Date().toISOString(),
    });
  });

  app.get("/api/info", (_req, res) => {
    res.json({
      app: config.appName,
      environment: config.environment,
      message: "Secure cost-predictable hosting stack is running on Docker.",
      auth: {
        provider: "cognito",
        configured: config.cognito.configured,
        inviteOnly: true,
        rbac: "custom-app-directory",
        mfa: "TOTP required when pool is live",
      },
      stack: {
        backend: "Node.js + TypeScript + Express",
        frontend: "React + Vite + TypeScript + Tailwind",
        runtime: "Docker Compose on EC2",
        auth: "Cognito (PKCE) + app user directory + RBAC",
      },
    });
  });

  app.use("/api", meRouter);
  app.use("/api", adminUsersRouter);

  app.use("/api", (_req, res) => {
    res.status(404).json({ ok: false, error: "Not found" });
  });

  app.use((err: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    if (res.headersSent) return;

    if (err instanceof ZodError) {
      res.status(400).json({
        ok: false,
        error: "Validation failed",
        code: "validation_error",
        details: err.flatten(),
      });
      return;
    }

    const maybe = err as { status?: number; code?: string; message?: string };
    if (typeof maybe.status === "number" && maybe.status >= 400 && maybe.status < 600) {
      res.status(maybe.status).json({
        ok: false,
        error: maybe.message ?? "Request failed",
        code: maybe.code ?? "error",
      });
      return;
    }

    console.error(err);
    res.status(500).json({ ok: false, error: "Internal server error" });
  });

  app.listen(config.port, "0.0.0.0", () => {
    console.log(
      `[${config.appName}] api listening on :${config.port} (${config.environment}) auth=${config.cognito.configured ? "on" : "off"} db=${config.databaseUrl ? "postgres" : "memory"}`,
    );
  });
}

main().catch((err) => {
  console.error("Failed to start API", err);
  process.exit(1);
});
