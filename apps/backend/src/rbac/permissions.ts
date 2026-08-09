/**
 * Canonical permission keys for the application RBAC system.
 * Cognito authenticates; these authorize.
 */
export const PERMISSIONS = [
  "users:read",
  "users:invite",
  "users:write",
  "users:delete",
  "roles:read",
  "admin:access",
] as const;

export type Permission = (typeof PERMISSIONS)[number];

export const ROLE_NAMES = ["admin", "member", "viewer"] as const;
export type RoleName = (typeof ROLE_NAMES)[number];

export const ROLE_PERMISSIONS: Record<RoleName, readonly Permission[]> = {
  admin: [...PERMISSIONS],
  member: [],
  viewer: ["users:read"],
};

export function isPermission(value: string): value is Permission {
  return (PERMISSIONS as readonly string[]).includes(value);
}
