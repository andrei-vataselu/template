import type { NextFunction, Request, Response } from "express";
import { assertCognitoAccountActive } from "../cognito/admin.js";
import type { Permission } from "../rbac/permissions.js";
import { syncUserFromAccessToken } from "../services/users.js";
import { AuthError, verifyAccessToken } from "./cognitoJwt.js";

const BEARER = /^Bearer\s+(.+)$/i;

function extractBearer(req: Request): string | null {
  const header = req.header("authorization");
  if (!header) return null;
  const match = BEARER.exec(header);
  return match?.[1]?.trim() || null;
}

function sendAuthError(res: Response, err: AuthError): void {
  res.setHeader("WWW-Authenticate", 'Bearer realm="api", error="invalid_token"');
  res.status(err.status).json({
    ok: false,
    error: err.message,
    code: err.code,
  });
}

/** Verify Cognito access token, sync/create local user, attach RBAC. */
export async function requireAuth(req: Request, res: Response, next: NextFunction): Promise<void> {
  try {
    const token = extractBearer(req);
    if (!token) {
      throw new AuthError("Missing Authorization Bearer token", "missing_token");
    }

    const identity = await verifyAccessToken(token);

    // Cognito disable/unconfirmed can outlive JWT expiry; check AdminGetUser (cached).
    const cognitoGate = await assertCognitoAccountActive({
      username: identity.username,
      cognitoSub: identity.sub,
    });
    if (cognitoGate === "disabled" || cognitoGate === "unconfirmed") {
      res.status(403).json({
        ok: false,
        error: cognitoGate === "unconfirmed" ? "Account not confirmed" : "Account disabled",
        code: cognitoGate === "unconfirmed" ? "account_unconfirmed" : "account_disabled",
      });
      return;
    }

    const appUser = await syncUserFromAccessToken(token, identity.sub, identity.username);

    if (appUser.status === "disabled") {
      res.status(403).json({
        ok: false,
        error: "Account disabled",
        code: "account_disabled",
      });
      return;
    }

    req.accessToken = token;
    req.user = {
      sub: identity.sub,
      username: identity.username,
      groups: identity.groups,
      scope: identity.scope,
      tokenExp: identity.tokenExp,
    };
    req.appUser = appUser;
    next();
  } catch (err) {
    if (err instanceof AuthError) {
      sendAuthError(res, err);
      return;
    }
    next(err);
  }
}

/** Custom RBAC: require all listed permissions on the local user record. */
export function requirePermission(...needed: Permission[]) {
  return (req: Request, res: Response, next: NextFunction): void => {
    const have = new Set(req.appUser?.permissions ?? []);
    const missing = needed.filter((p) => !have.has(p));
    if (missing.length) {
      res.status(403).json({
        ok: false,
        error: "Insufficient permissions",
        code: "forbidden",
        missing,
      });
      return;
    }
    next();
  };
}
