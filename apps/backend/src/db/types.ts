import { ROLE_NAMES, ROLE_PERMISSIONS, type RoleName } from "../rbac/permissions.js";

export type UserStatus = "active" | "disabled" | "invited";

/** Local directory record — identity PII stays in Cognito only. */
export type AppUser = {
  id: string;
  cognitoSub: string;
  status: UserStatus;
  roles: RoleName[];
  permissions: string[];
  createdAt: Date;
  updatedAt: Date;
  lastLoginAt: Date | null;
};

export type UpsertFromIdentityInput = {
  cognitoSub: string;
  touchLogin?: boolean;
  /** Role assignment for brand-new rows only */
  initialRoles?: RoleName[];
};

export type InviteUserInput = {
  cognitoSub: string;
  roles: RoleName[];
};

export interface IdentityStore {
  readonly driver: "postgres" | "memory";
  ready(): Promise<void>;
  upsertFromIdentity(input: UpsertFromIdentityInput): Promise<AppUser>;
  createInvitedUser(input: InviteUserInput): Promise<AppUser>;
  getById(id: string): Promise<AppUser | null>;
  getByCognitoSub(sub: string): Promise<AppUser | null>;
  listUsers(): Promise<AppUser[]>;
  countUsers(): Promise<number>;
  setStatus(id: string, status: UserStatus): Promise<AppUser>;
  setRoles(id: string, roles: RoleName[]): Promise<AppUser>;
  deleteUser(id: string): Promise<void>;
  listRoles(): Promise<Array<{ name: RoleName; description: string | null; permissions: string[] }>>;
}

export function assertRoleName(name: string): RoleName {
  if (!(ROLE_NAMES as readonly string[]).includes(name)) {
    throw new Error(`Unknown role: ${name}`);
  }
  return name as RoleName;
}

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

export { ROLE_NAMES, ROLE_PERMISSIONS, type RoleName };
