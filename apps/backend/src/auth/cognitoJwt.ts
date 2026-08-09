import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import { config } from "../config.js";
import type { AuthenticatedUser, CognitoAccessTokenClaims } from "./types.js";

let jwks: JWTVerifyGetKey | null = null;

function getJwks(): JWTVerifyGetKey {
  if (!jwks) {
    const url = config.cognito.jwksUrl;
    if (!url) {
      throw new Error("Cognito JWKS URL is not configured");
    }
    // Cache keys; jose refreshes on kid miss / rotation.
    jwks = createRemoteJWKSet(url, {
      cooldownDuration: 30_000,
      cacheMaxAge: 600_000,
    });
  }
  return jwks;
}

export class AuthError extends Error {
  constructor(
    message: string,
    readonly code:
      | "missing_token"
      | "invalid_token"
      | "wrong_token_use"
      | "wrong_client"
      | "auth_not_configured",
    readonly status = 401,
  ) {
    super(message);
    this.name = "AuthError";
  }
}

export async function verifyAccessToken(token: string): Promise<AuthenticatedUser> {
  if (!config.cognito.configured || !config.cognito.issuer || !config.cognito.clientId) {
    throw new AuthError("Authentication is not configured", "auth_not_configured", 503);
  }

  let payload: CognitoAccessTokenClaims;
  try {
    const result = await jwtVerify(token, getJwks(), {
      issuer: config.cognito.issuer,
      // Cognito access tokens omit standard `aud`; validate `client_id` below.
      clockTolerance: 30,
      algorithms: ["RS256"],
    });
    payload = result.payload as CognitoAccessTokenClaims;
  } catch {
    throw new AuthError("Invalid or expired access token", "invalid_token");
  }

  if (payload.token_use !== "access") {
    throw new AuthError("ID tokens are not accepted; use an access token", "wrong_token_use");
  }

  if (payload.client_id !== config.cognito.clientId) {
    throw new AuthError("Token was not issued for this application", "wrong_client");
  }

  if (typeof payload.sub !== "string" || payload.sub.length === 0) {
    throw new AuthError("Token is missing subject", "invalid_token");
  }

  const groups = Array.isArray(payload["cognito:groups"])
    ? payload["cognito:groups"].filter((g): g is string => typeof g === "string")
    : [];

  const scope =
    typeof payload.scope === "string"
      ? payload.scope.split(" ").map((s) => s.trim()).filter(Boolean)
      : [];

  return {
    sub: payload.sub,
    username: typeof payload.username === "string" ? payload.username : undefined,
    groups,
    scope,
    tokenExp: typeof payload.exp === "number" ? payload.exp : undefined,
  };
}
