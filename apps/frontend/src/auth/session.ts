/**
 * Token + PKCE state storage.
 * - Session tokens: localStorage (shared across tabs in the same browser profile).
 * - PKCE pending: sessionStorage (one-time, tab-scoped).
 */

const PREFIX = "popo.auth.";
const SESSION_KEY = `${PREFIX}session`;
const PENDING_KEY = `${PREFIX}pending`;

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

function read(store: Storage, key: string): string | null {
  try {
    return store.getItem(key);
  } catch {
    return null;
  }
}

function write(store: Storage, key: string, value: string): void {
  store.setItem(key, value);
}

function remove(store: Storage, key: string): void {
  store.removeItem(key);
}

/** Migrate older sessionStorage sessions once so existing logins survive the switch. */
function migrateSessionFromSessionStorage(): void {
  try {
    if (localStorage.getItem(SESSION_KEY)) return;
    const legacy = sessionStorage.getItem(SESSION_KEY);
    if (!legacy) return;
    localStorage.setItem(SESSION_KEY, legacy);
    sessionStorage.removeItem(SESSION_KEY);
  } catch {
    /* ignore quota / private mode */
  }
}

export function savePendingAuth(pending: PendingAuth): void {
  write(sessionStorage, PENDING_KEY, JSON.stringify(pending));
}

export function loadPendingAuth(): PendingAuth | null {
  const raw = read(sessionStorage, PENDING_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as PendingAuth;
  } catch {
    return null;
  }
}

export function clearPendingAuth(): void {
  remove(sessionStorage, PENDING_KEY);
}

export function saveSession(session: StoredSession): void {
  write(localStorage, SESSION_KEY, JSON.stringify(session));
  // Drop legacy copy so tabs don't diverge.
  try {
    sessionStorage.removeItem(SESSION_KEY);
  } catch {
    /* ignore */
  }
}

export function loadSession(): StoredSession | null {
  migrateSessionFromSessionStorage();
  const raw = read(localStorage, SESSION_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as StoredSession;
  } catch {
    return null;
  }
}

export function clearSession(): void {
  remove(localStorage, SESSION_KEY);
  try {
    sessionStorage.removeItem(SESSION_KEY);
  } catch {
    /* ignore */
  }
}

export function clearAllAuthStorage(): void {
  clearPendingAuth();
  clearSession();
}

/** True when another tab wrote/cleared the shared session key. */
export function isSessionStorageEvent(ev: StorageEvent): boolean {
  return ev.storageArea === localStorage && ev.key === SESSION_KEY;
}
