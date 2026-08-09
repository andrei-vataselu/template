import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import {
  beginLogin,
  getSession,
  isAuthConfigured,
  logout as cognitoLogout,
  logoutLocal,
  readIdTokenClaims,
  refreshSession,
  type IdTokenClaims,
} from "./cognitoAuth";
import { isSessionStorageEvent, type StoredSession } from "./session";

type AuthStatus = "loading" | "anonymous" | "authenticated" | "unconfigured";

type AuthContextValue = {
  status: AuthStatus;
  session: StoredSession | null;
  claims: IdTokenClaims | null;
  configured: boolean;
  login: () => Promise<void>;
  logout: () => void;
  refresh: () => Promise<void>;
};

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const configured = isAuthConfigured();
  const [status, setStatus] = useState<AuthStatus>(configured ? "loading" : "unconfigured");
  const [session, setSession] = useState<StoredSession | null>(null);

  const hydrate = useCallback(async () => {
    if (!configured) {
      setStatus("unconfigured");
      setSession(null);
      return;
    }
    let current = getSession();
    if (current && current.expiresAt - Date.now() < 60_000) {
      current = await refreshSession();
    }
    if (current) {
      setSession(current);
      setStatus("authenticated");
    } else {
      setSession(null);
      setStatus("anonymous");
    }
  }, [configured]);

  useEffect(() => {
    void hydrate();
  }, [hydrate]);

  // Keep tabs in sync when another tab signs in / out (localStorage session).
  useEffect(() => {
    const onStorage = (ev: StorageEvent) => {
      if (!isSessionStorageEvent(ev)) return;
      void hydrate();
    };
    window.addEventListener("storage", onStorage);
    return () => window.removeEventListener("storage", onStorage);
  }, [hydrate]);

  const login = useCallback(async () => {
    await beginLogin();
  }, []);

  const logout = useCallback(() => {
    cognitoLogout();
  }, []);

  const refresh = useCallback(async () => {
    const next = await refreshSession();
    if (next) {
      setSession(next);
      setStatus("authenticated");
    } else {
      logoutLocal();
      setSession(null);
      setStatus("anonymous");
    }
  }, []);

  const claims = useMemo(
    () => (session ? readIdTokenClaims(session.idToken) : null),
    [session],
  );

  const value = useMemo<AuthContextValue>(
    () => ({ status, session, claims, configured, login, logout, refresh }),
    [status, session, claims, configured, login, logout, refresh],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
