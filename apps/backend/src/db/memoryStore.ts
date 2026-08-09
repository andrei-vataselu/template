import { randomUUID } from "node:crypto";
import {
  PERMISSIONS,
  ROLE_NAMES,
  ROLE_PERMISSIONS,
  type RoleName,
} from "../rbac/permissions.js";
import {
  assertRoleName,
  type AppUser,
  type IdentityStore,
  type InviteUserInput,
  type UpsertFromIdentityInput,
  type UserStatus,
} from "./types.js";

type MemUser = {
  id: string;
  cognitoSub: string;
  status: UserStatus;
  roleNames: Set<RoleName>;
  createdAt: Date;
  updatedAt: Date;
  lastLoginAt: Date | null;
};

function permissionsFor(roles: Iterable<RoleName>): string[] {
  const set = new Set<string>();
  for (const role of roles) {
    for (const p of ROLE_PERMISSIONS[role]) set.add(p);
  }
  return [...set].sort();
}

function toAppUser(u: MemUser): AppUser {
  const roles = [...u.roleNames].sort() as RoleName[];
  return {
    id: u.id,
    cognitoSub: u.cognitoSub,
    status: u.status,
    roles,
    permissions: permissionsFor(u.roleNames),
    createdAt: u.createdAt,
    updatedAt: u.updatedAt,
    lastLoginAt: u.lastLoginAt,
  };
}

export class MemoryIdentityStore implements IdentityStore {
  readonly driver = "memory" as const;
  private users = new Map<string, MemUser>();
  private bySub = new Map<string, string>();
  private readyFlag = false;

  async ready(): Promise<void> {
    this.readyFlag = true;
  }

  private requireReady(): void {
    if (!this.readyFlag) throw new Error("Identity store not initialized");
  }

  private getOrThrow(id: string): MemUser {
    const u = this.users.get(id);
    if (!u) throw new Error("User not found");
    return u;
  }

  async countUsers(): Promise<number> {
    return this.users.size;
  }

  async upsertFromIdentity(input: UpsertFromIdentityInput): Promise<AppUser> {
    this.requireReady();
    const existingId = this.bySub.get(input.cognitoSub);
    const now = new Date();

    if (existingId) {
      const u = this.getOrThrow(existingId);
      if (u.status === "invited") u.status = "active";
      u.updatedAt = now;
      if (input.touchLogin) u.lastLoginAt = now;
      return toAppUser(u);
    }

    const id = randomUUID();
    const roles = input.initialRoles?.length ? input.initialRoles : (["member"] as RoleName[]);
    const u: MemUser = {
      id,
      cognitoSub: input.cognitoSub,
      status: "active",
      roleNames: new Set(roles.map(assertRoleName)),
      createdAt: now,
      updatedAt: now,
      lastLoginAt: input.touchLogin ? now : null,
    };
    this.users.set(id, u);
    this.bySub.set(u.cognitoSub, id);
    return toAppUser(u);
  }

  async createInvitedUser(input: InviteUserInput): Promise<AppUser> {
    this.requireReady();
    if (this.bySub.has(input.cognitoSub)) {
      throw new Error("User already exists");
    }
    const now = new Date();
    const id = randomUUID();
    const roles = input.roles.length ? input.roles.map(assertRoleName) : (["member"] as RoleName[]);
    const u: MemUser = {
      id,
      cognitoSub: input.cognitoSub,
      status: "invited",
      roleNames: new Set(roles),
      createdAt: now,
      updatedAt: now,
      lastLoginAt: null,
    };
    this.users.set(id, u);
    this.bySub.set(u.cognitoSub, id);
    return toAppUser(u);
  }

  async getById(id: string): Promise<AppUser | null> {
    const u = this.users.get(id);
    return u ? toAppUser(u) : null;
  }

  async getByCognitoSub(sub: string): Promise<AppUser | null> {
    const id = this.bySub.get(sub);
    return id ? this.getById(id) : null;
  }

  async listUsers(): Promise<AppUser[]> {
    return [...this.users.values()]
      .map(toAppUser)
      .sort((a, b) => a.cognitoSub.localeCompare(b.cognitoSub));
  }

  async setStatus(id: string, status: UserStatus): Promise<AppUser> {
    const u = this.getOrThrow(id);
    u.status = status;
    u.updatedAt = new Date();
    return toAppUser(u);
  }

  async setRoles(id: string, roles: RoleName[]): Promise<AppUser> {
    const u = this.getOrThrow(id);
    u.roleNames = new Set(roles.map(assertRoleName));
    u.updatedAt = new Date();
    return toAppUser(u);
  }

  async deleteUser(id: string): Promise<void> {
    const u = this.users.get(id);
    if (!u) return;
    this.users.delete(id);
    this.bySub.delete(u.cognitoSub);
  }

  async listRoles() {
    return ROLE_NAMES.map((name) => ({
      name,
      description: name === "admin" ? "Full access" : name === "viewer" ? "Read-only" : "Standard user",
      permissions: [...ROLE_PERMISSIONS[name]],
    }));
  }
}

void PERMISSIONS;
