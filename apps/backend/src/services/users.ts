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

function httpError(message: string, code: string, status: number): Error {
  return Object.assign(new Error(message), { code, status });
}

async function countAdmins(excludeUserId?: string): Promise<number> {
  const users = await getIdentityStore().listUsers();
  return users.filter(
    (u) =>
      u.id !== excludeUserId &&
      u.status !== "disabled" &&
      u.roles.includes("admin"),
  ).length;
}

async function assertNotLastAdmin(user: AppUser, nextRoles?: RoleName[]): Promise<void> {
  const isAdmin = user.roles.includes("admin") && user.status !== "disabled";
  if (!isAdmin) return;

  const wouldLoseAdmin =
    nextRoles !== undefined ? !nextRoles.includes("admin") : true;
  if (!wouldLoseAdmin) return;

  if ((await countAdmins(user.id)) < 1) {
    throw httpError("Cannot remove or disable the last admin", "last_admin", 409);
  }
}

/** Invite / role APIs never mint admin — bootstrap env or existing admin DB only. */
export function parseAssignableRoles(input: unknown): RoleName[] {
  if (!Array.isArray(input)) return ["member"];
  const roles = input
    .filter((r): r is string => typeof r === "string")
    .map(assertRoleName)
    .filter((r) => r !== "admin");
  if (input.some((r) => r === "admin")) {
    throw httpError(
      "Assigning admin via API is not allowed; use BOOTSTRAP_ADMIN_EMAILS/SUBS",
      "admin_assign_forbidden",
      403,
    );
  }
  return roles.length ? roles : ["member"];
}

async function resolveInitialRoles(cognitoSub: string, accessToken: string): Promise<RoleName[]> {
  const store = getIdentityStore();
  const existing = await store.getByCognitoSub(cognitoSub);
  if (existing) return existing.roles;

  // One-shot bootstrap: only mint admin while the directory has zero admins.
  // Once any admin exists, BOOTSTRAP_ADMIN_EMAILS/SUBS do nothing.
  if ((await countAdmins()) > 0) {
    return ["member"];
  }

  const subs = bootstrapAdminSubs();
  if (subs.has(cognitoSub)) return ["admin"];

  const emails = bootstrapAdminEmails();
  if (emails.size > 0) {
    const profile = await getProfileFromAccessToken(accessToken);
    if (emails.has(normalizeEmail(profile.email))) return ["admin"];
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

  if (config.inviteOnly) {
    // Allow bootstrap admins through even when invite-only.
    const initialRoles = await resolveInitialRoles(cognitoSub, accessToken);
    if (!initialRoles.includes("admin")) {
      throw httpError("User is not invited", "not_invited", 403);
    }
    return store.upsertFromIdentity({
      cognitoSub,
      touchLogin: true,
      initialRoles,
    });
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
    throw httpError("Cognito is not configured", "auth_not_configured", 503);
  }

  if (roles.includes("admin")) {
    throw httpError(
      "Assigning admin via invite is not allowed",
      "admin_assign_forbidden",
      403,
    );
  }

  const cognito = await adminInviteUser(email);
  const store = getIdentityStore();
  if (await store.getByCognitoSub(cognito.sub)) {
    throw httpError("User already exists in directory", "conflict", 409);
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
    throw httpError("User not found", "not_found", 404);
  }

  if (disabled) {
    await assertNotLastAdmin(user);
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
    throw httpError("User not found", "not_found", 404);
  }
  const next = roles.map(assertRoleName);
  if (next.includes("admin") && !user.roles.includes("admin")) {
    throw httpError(
      "Assigning admin via API is not allowed; use BOOTSTRAP_ADMIN_EMAILS/SUBS",
      "admin_assign_forbidden",
      403,
    );
  }
  await assertNotLastAdmin(user, next);
  return store.setRoles(userId, next);
}

export async function removeUser(userId: string): Promise<void> {
  const store = getIdentityStore();
  const user = await store.getById(userId);
  if (!user) {
    throw httpError("User not found", "not_found", 404);
  }
  await assertNotLastAdmin(user);
  await adminDeleteBySub(user.cognitoSub);
  await store.deleteUser(userId);
}

/** @deprecated use parseAssignableRoles — kept for callers that only need member/viewer */
export function parseRoles(input: unknown): RoleName[] {
  return parseAssignableRoles(input);
}

export { ROLE_NAMES };
export type { AppUser, RoleName };
