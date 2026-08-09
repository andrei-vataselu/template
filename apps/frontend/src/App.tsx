import { FormEvent, useEffect, useState } from "react";
import { apiFetch, ApiError } from "./api/client";
import { useAuth } from "./auth/AuthContext";
import { AuthShell } from "./auth/AuthShell";
import { completeLogin } from "./auth/cognitoAuth";
import { ensureHttpsOrigin } from "./auth/config";

type Health = {
  ok: boolean;
  app: string;
  environment: string;
  authConfigured: boolean;
  directory?: string;
  time: string;
};

type Info = {
  message: string;
  auth: { configured: boolean; inviteOnly: boolean; rbac?: string };
  stack: Record<string, string>;
};

type MeResponse = {
  ok: boolean;
  identity: {
    sub: string;
    username?: string;
    cognitoGroups: string[];
    scope: string[];
  };
  user: {
    id: string;
    cognitoSub: string;
    status: string;
    roles: string[];
    permissions: string[];
    lastLoginAt: string | null;
  };
};

type DirectoryUser = {
  id: string;
  cognitoSub: string;
  status: string;
  roles: string[];
};

function CallbackPage() {
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await completeLogin();
        if (!cancelled) {
          window.history.replaceState({}, document.title, "/");
          window.location.assign("/");
        }
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : "Login failed");
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div className="page">
      <main className="hero">
        <h1>Signing you in</h1>
        {error ? (
          <>
            <p className="error">{error}</p>
            <p className="lede">
              <a href="/">Return home</a> and try again.
            </p>
          </>
        ) : (
          <p className="muted">Completing secure sign-in…</p>
        )}
      </main>
    </div>
  );
}

function LogoutPage() {
  useEffect(() => {
    window.setTimeout(() => window.location.replace("/"), 800);
  }, []);

  return (
    <div className="page">
      <main className="hero">
        <h1>Signed out</h1>
        <p className="muted">Redirecting…</p>
      </main>
    </div>
  );
}

function HomePage() {
  const auth = useAuth();
  const [health, setHealth] = useState<Health | null>(null);
  const [info, setInfo] = useState<Info | null>(null);
  const [me, setMe] = useState<MeResponse | null>(null);
  const [users, setUsers] = useState<DirectoryUser[]>([]);
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteMsg, setInviteMsg] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [meError, setMeError] = useState<string | null>(null);

  const canInvite = Boolean(me?.user.permissions.includes("users:invite"));
  const canReadUsers = Boolean(me?.user.permissions.includes("users:read"));

  useEffect(() => {
    let cancelled = false;

    async function loadPublic() {
      try {
        const [healthJson, infoJson] = await Promise.all([
          apiFetch<Health>("/api/health"),
          apiFetch<Info>("/api/info"),
        ]);
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

    void loadPublic();
    const id = window.setInterval(() => void loadPublic(), 15000);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    if (auth.status !== "authenticated") {
      setMe(null);
      setUsers([]);
      setMeError(null);
      return;
    }

    (async () => {
      try {
        const res = await apiFetch<MeResponse>("/api/me", { auth: true });
        if (cancelled) return;
        setMe(res);
        setMeError(null);

        if (res.user.permissions.includes("users:read")) {
          const list = await apiFetch<{ users: DirectoryUser[] }>("/api/admin/users", {
            auth: true,
          });
          if (!cancelled) setUsers(list.users);
        }
      } catch (err) {
        if (!cancelled) {
          setMe(null);
          setMeError(err instanceof ApiError ? err.message : "Failed to load profile");
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [auth.status]);

  async function onInvite(e: FormEvent) {
    e.preventDefault();
    setInviteMsg(null);
    try {
      await apiFetch("/api/admin/users", {
        method: "POST",
        auth: true,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: inviteEmail, roles: ["member"] }),
      });
      setInviteEmail("");
      setInviteMsg("Invite sent via Cognito and recorded in the app directory.");
      const list = await apiFetch<{ users: DirectoryUser[] }>("/api/admin/users", { auth: true });
      setUsers(list.users);
    } catch (err) {
      setInviteMsg(err instanceof ApiError ? err.message : "Invite failed");
    }
  }

  return (
    <div className="page">
      <div className="glow" aria-hidden />
      <header className="nav">
        <p className="brand">template</p>
        <div className="nav-actions">
          <p className="env-pill">{health?.environment ?? "…"}</p>
          {auth.status === "authenticated" ? (
            <button type="button" className="btn ghost" onClick={() => auth.logout()}>
              Sign out
            </button>
          ) : auth.configured ? (
            <>
              <button
                type="button"
                className="btn ghost"
                onClick={() => window.location.assign("/signup")}
                disabled={auth.status === "loading"}
              >
                Sign up
              </button>
              <button
                type="button"
                className="btn"
                onClick={() => void auth.login()}
                disabled={auth.status === "loading"}
              >
                Sign in
              </button>
            </>
          ) : null}
        </div>
      </header>

      <main className="hero">
        <h1>Identity + RBAC</h1>
        <p className="lede">
          Cognito holds identity. The API stores only Cognito user ids plus roles/permissions — no
          emails or profile PII in the app database.
        </p>

        {!auth.configured ? (
          <section className="panel">
            <h2>Auth config</h2>
            <p className="muted">
              Set <code>VITE_COGNITO_*</code> on the frontend and <code>COGNITO_*</code> on the API.
              Optional <code>DATABASE_URL</code> for Postgres (otherwise in-memory directory).
            </p>
          </section>
        ) : null}

        <section className="panel">
          <h2>API status</h2>
          {error ? (
            <p className="error">{error}</p>
          ) : health ? (
            <ul>
              <li>
                <span>Health</span>
                <strong className="ok">{health.ok ? "ok" : "down"}</strong>
              </li>
              <li>
                <span>Directory</span>
                <strong>{health.directory ?? "—"}</strong>
              </li>
              <li>
                <span>Cognito</span>
                <strong>{health.authConfigured ? "configured" : "off"}</strong>
              </li>
            </ul>
          ) : (
            <p className="muted">Checking API…</p>
          )}
        </section>

        <section className="panel secondary">
          <h2>App user (/api/me)</h2>
          {auth.status !== "authenticated" ? (
            <p className="muted">Sign in to sync into the backend directory.</p>
          ) : meError ? (
            <p className="error">{meError}</p>
          ) : me ? (
            <ul>
              <li>
                <span>Cognito sub</span>
                <strong className="mono">{me.user.cognitoSub}</strong>
              </li>
              <li>
                <span>Status</span>
                <strong>{me.user.status}</strong>
              </li>
              <li>
                <span>Roles</span>
                <strong>{me.user.roles.join(", ") || "—"}</strong>
              </li>
              <li>
                <span>Permissions</span>
                <strong>{me.user.permissions.join(", ") || "—"}</strong>
              </li>
            </ul>
          ) : (
            <p className="muted">Loading profile…</p>
          )}
        </section>

        {canReadUsers ? (
          <section className="panel secondary">
            <h2>Directory</h2>
            {users.length === 0 ? (
              <p className="muted">No users yet.</p>
            ) : (
              <ul>
                {users.map((u) => (
                  <li key={u.id}>
                    <span className="mono">{u.cognitoSub}</span>
                    <strong>
                      {u.status} · {u.roles.join(", ")}
                    </strong>
                  </li>
                ))}
              </ul>
            )}
            {canInvite ? (
              <form className="invite-form" onSubmit={(e) => void onInvite(e)}>
                <input
                  type="email"
                  required
                  placeholder="colleague@company.com"
                  value={inviteEmail}
                  onChange={(e) => setInviteEmail(e.target.value)}
                  aria-label="Invite email"
                />
                <button type="submit" className="btn">
                  Invite
                </button>
              </form>
            ) : null}
            {inviteMsg ? <p className="muted">{inviteMsg}</p> : null}
          </section>
        ) : null}

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

export default function App() {
  ensureHttpsOrigin();
  const path = window.location.pathname.replace(/\/+$/, "") || "/";

  if (path === "/callback") return <CallbackPage />;
  if (path === "/logout") return <LogoutPage />;
  if (path === "/login") {
    return <AuthShell screen="login" />;
  }
  if (path === "/signup") {
    return <AuthShell screen="signup" />;
  }
  if (path === "/forgot-password") {
    return <AuthShell screen="forgotPassword" />;
  }
  return <HomePage />;
}
