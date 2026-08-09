/**
 * Token + PKCE state storage.
 * sessionStorage only (not localStorage) to limit XSS persistence across tabs/sessions.
 */

const PREFIX = "popo.auth.";

export type StoredSession = {
  accessToken: string;
  idToken: string;
  refreshToken: string;
  expiresAt: number;
  scope: string;
  tokenType: string;
};

export type PendingAuth = {
  state: string;
  nonce: string;
  verifier: string;
  createdAt: number;
};

function get(key: string): string | null {
  try {
    return sessionStorage.getItem(PREFIX + key);
  } catch {
    return null;
  }
}

function set(key: string, value: string): void {
  sessionStorage.setItem(PREFIX + key, value);
}

function remove(key: string): void {
  sessionStorage.removeItem(PREFIX + key);
}

export function savePendingAuth(pending: PendingAuth): void {
  set("pending", JSON.stringify(pending));
}

export function loadPendingAuth(): PendingAuth | null {
  const raw = get("pending");
  if (!raw) return null;
  try {
    return JSON.parse(raw) as PendingAuth;
  } catch {
    return null;
  }
}

export function clearPendingAuth(): void {
  remove("pending");
}

export function saveSession(session: StoredSession): void {
  set("session", JSON.stringify(session));
}

export function loadSession(): StoredSession | null {
  const raw = get("session");
  if (!raw) return null;
  try {
    return JSON.parse(raw) as StoredSession;
  } catch {
    return null;
  }
}

export function clearSession(): void {
  remove("session");
}

export function clearAllAuthStorage(): void {
  clearPendingAuth();
  clearSession();
}
