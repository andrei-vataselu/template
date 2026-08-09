import {
  adminDeleteBySub,
  adminDeleteUser,
  adminDisableBySub,
  adminEnableBySub,
  adminInviteUser,
  getProfileFromAccessToken,
} from "../cognito/admin.js";
import { getIdentityStore } from "../db/client.js";
import { assertRoleName, normalizeEmail, type AppUser, type RoleName } from "../db/types.js";
import { ROLE_NAMES } from "../rbac/permissions.js";
import { config } from "../config.js";

function bootstrapAdminEmails(): Set<string> {
  return new Set(
    (process.env.BOOTSTRAP_ADMIN_EMAILS ?? "")
      .split(",")
      .map((s) => normalizeEmail(s))
      .filter(Boolean),
  );
}

function bootstrapAdminSubs(): Set<string> {
  return new Set(
    (process.env.BOOTSTRAP_ADMIN_SUBS ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
}

async function resolveInitialRoles(cognitoSub: string, accessToken: string): Promise<RoleName[]> {
  const store = getIdentityStore();
  const existing = await store.getByCognitoSub(cognitoSub);
  if (existing) return existing.roles;

  const subs = bootstrapAdminSubs();
  if (subs.has(cognitoSub)) return ["admin"];

  const emails = bootstrapAdminEmails();
  if (emails.size > 0) {
    // Email is read from Cognito for bootstrap matching only — never written to DB.
    const profile = await getProfileFromAccessToken(accessToken);
    if (emails.has(normalizeEmail(profile.email))) return ["admin"];
  }

  if (emails.size === 0 && subs.size === 0 && (await store.countUsers()) === 0) {
    return ["admin"];
  }

  return ["member"];
}

/** Sync local RBAC row from Cognito sub only (no PII stored). */
export async function syncUserFromAccessToken(
  accessToken: string,
  cognitoSub: string,
): Promise<AppUser> {
  const store = getIdentityStore();
  const existing = await store.getByCognitoSub(cognitoSub);
  if (existing) {
    return store.upsertFromIdentity({ cognitoSub, touchLogin: true });
  }

  const initialRoles = await resolveInitialRoles(cognitoSub, accessToken);
  return store.upsertFromIdentity({
    cognitoSub,
    touchLogin: true,
    initialRoles,
  });
}

export async function inviteUser(email: string, roles: RoleName[]): Promise<AppUser> {
  if (!config.cognito.configured) {
    throw Object.assign(new Error("Cognito is not configured"), {
      code: "auth_not_configured",
      status: 503,
    });
  }

  const cognito = await adminInviteUser(email);
  const store = getIdentityStore();
  if (await store.getByCognitoSub(cognito.sub)) {
    throw Object.assign(new Error("User already exists in directory"), {
      code: "conflict",
      status: 409,
    });
  }

  try {
    return await store.createInvitedUser({
      cognitoSub: cognito.sub,
      roles: roles.length ? roles : ["member"],
    });
  } catch (err) {
    await adminDeleteUser(cognito.username).catch(() => undefined);
    throw err;
  }
}

export async function setUserDisabled(userId: string, disabled: boolean): Promise<AppUser> {
  const store = getIdentityStore();
  const user = await store.getById(userId);
  if (!user) {
    throw Object.assign(new Error("User not found"), { code: "not_found", status: 404 });
  }

  if (disabled) {
    await adminDisableBySub(user.cognitoSub);
    return store.setStatus(userId, "disabled");
  }

  await adminEnableBySub(user.cognitoSub);
  return store.setStatus(userId, user.status === "invited" ? "invited" : "active");
}

export async function updateUserRoles(userId: string, roles: string[]): Promise<AppUser> {
  const store = getIdentityStore();
  const user = await store.getById(userId);
  if (!user) {
    throw Object.assign(new Error("User not found"), { code: "not_found", status: 404 });
  }
  return store.setRoles(userId, roles.map(assertRoleName));
}

export async function removeUser(userId: string): Promise<void> {
  const store = getIdentityStore();
  const user = await store.getById(userId);
  if (!user) {
    throw Object.assign(new Error("User not found"), { code: "not_found", status: 404 });
  }
  await adminDeleteBySub(user.cognitoSub);
  await store.deleteUser(userId);
}

export function parseRoles(input: unknown): RoleName[] {
  if (!Array.isArray(input)) return ["member"];
  const roles = input.filter((r): r is string => typeof r === "string").map(assertRoleName);
  return roles.length ? roles : ["member"];
}

export { ROLE_NAMES };
export type { AppUser, RoleName };
