import { loadCognitoConfig, type CognitoPublicConfig } from "./config";
import { createPkceChallenge, randomUrlSafe } from "./pkce";
import {
  clearAllAuthStorage,
  clearPendingAuth,
  loadPendingAuth,
  loadSession,
  savePendingAuth,
  saveSession,
  type StoredSession,
} from "./session";

type TokenResponse = {
  access_token: string;
  id_token: string;
  refresh_token?: string;
  expires_in: number;
  token_type: string;
  scope?: string;
};

export type IdTokenClaims = {
  sub: string;
  email?: string;
  email_verified?: boolean;
  "cognito:username"?: string;
  "cognito:groups"?: string[];
  exp?: number;
};

/** Cognito Hosted UI screens — auth logic lives entirely in Cognito. */
export type CognitoAuthScreen = "login" | "signup" | "forgotPassword";

function decodeJwtPayload(token: string): Record<string, unknown> {
  const part = token.split(".")[1];
  if (!part) throw new Error("Malformed JWT");
  const padded = part.replace(/-/g, "+").replace(/_/g, "/");
  const json = atob(padded.padEnd(padded.length + ((4 - (padded.length % 4)) % 4), "="));
  return JSON.parse(json) as Record<string, unknown>;
}

export function readIdTokenClaims(idToken: string): IdTokenClaims {
  return decodeJwtPayload(idToken) as IdTokenClaims;
}

function sessionFromTokenResponse(tokens: TokenResponse, previous?: StoredSession | null): StoredSession {
  return {
    accessToken: tokens.access_token,
    idToken: tokens.id_token,
    refreshToken: tokens.refresh_token ?? previous?.refreshToken ?? "",
    expiresAt: Date.now() + tokens.expires_in * 1000,
    scope: tokens.scope ?? previous?.scope ?? "",
    tokenType: tokens.token_type || "Bearer",
  };
}

async function postToken(cfg: CognitoPublicConfig, body: URLSearchParams): Promise<TokenResponse> {
  const res = await fetch(`${cfg.hostedUiBase}/oauth2/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
  });
  if (!res.ok) {
    throw new Error("Token exchange failed");
  }
  return (await res.json()) as TokenResponse;
}

export function isAuthConfigured(): boolean {
  return loadCognitoConfig() !== null;
}

/**
 * Hand the browser to Cognito Hosted UI (HTTPS).
 * The SPA only starts PKCE + handles /callback — passwords never touch our servers.
 */
export async function beginAuth(screen: CognitoAuthScreen = "login"): Promise<void> {
  const cfg = loadCognitoConfig();
  if (!cfg) throw new Error("Cognito is not configured");

  const state = randomUrlSafe(16);
  const nonce = randomUrlSafe(16);
  const { verifier, challenge } = await createPkceChallenge();

  savePendingAuth({ state, nonce, verifier, createdAt: Date.now() });

  const params = new URLSearchParams({
    client_id: cfg.clientId,
    response_type: "code",
    scope: cfg.scopes.join(" "),
    redirect_uri: cfg.redirectUri,
    state,
    nonce,
    code_challenge_method: "S256",
    code_challenge: challenge,
  });

  window.location.assign(`${cfg.hostedUiBase}/${screen}?${params.toString()}`);
}

export async function beginLogin(): Promise<void> {
  return beginAuth("login");
}

export async function completeLogin(url: URL = new URL(window.location.href)): Promise<StoredSession> {
  const cfg = loadCognitoConfig();
  if (!cfg) throw new Error("Cognito is not configured");

  const err = url.searchParams.get("error");
  if (err) {
    const desc = url.searchParams.get("error_description") ?? err;
    clearPendingAuth();
    throw new Error(desc);
  }

  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const pending = loadPendingAuth();

  if (!code || !state || !pending) {
    throw new Error("Missing authorization response");
  }
  if (state !== pending.state) {
    clearPendingAuth();
    throw new Error("Invalid OAuth state");
  }
  if (Date.now() - pending.createdAt > 10 * 60 * 1000) {
    clearPendingAuth();
    throw new Error("Login session expired; try again");
  }

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: cfg.clientId,
    code,
    redirect_uri: cfg.redirectUri,
    code_verifier: pending.verifier,
  });

  const tokens = await postToken(cfg, body);
  const claims = readIdTokenClaims(tokens.id_token);
  if (typeof claims.sub !== "string") {
    throw new Error("ID token missing subject");
  }

  const session = sessionFromTokenResponse(tokens);
  clearPendingAuth();
  saveSession(session);
  return session;
}

export async function refreshSession(): Promise<StoredSession | null> {
  const cfg = loadCognitoConfig();
  const current = loadSession();
  if (!cfg || !current?.refreshToken) return null;

  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: cfg.clientId,
    refresh_token: current.refreshToken,
  });

  try {
    const tokens = await postToken(cfg, body);
    const session = sessionFromTokenResponse(tokens, current);
    saveSession(session);
    return session;
  } catch {
    clearAllAuthStorage();
    return null;
  }
}

export async function getValidAccessToken(): Promise<string | null> {
  let session = loadSession();
  if (!session) return null;

  if (session.expiresAt - Date.now() < 60_000) {
    const refreshed = await refreshSession();
    if (!refreshed) return null;
    session = refreshed;
  }
  return session.accessToken;
}

export function getSession(): StoredSession | null {
  return loadSession();
}

export function logoutLocal(): void {
  clearAllAuthStorage();
}

/** Cognito Hosted UI logout (clears Cognito cookies) + local session wipe. */
export function logout(): void {
  const cfg = loadCognitoConfig();
  clearAllAuthStorage();
  if (!cfg) {
    window.location.assign("/");
    return;
  }
  const params = new URLSearchParams({
    client_id: cfg.clientId,
    logout_uri: cfg.logoutUri,
  });
  window.location.assign(`${cfg.hostedUiBase}/logout?${params.toString()}`);
}
