import { eq, inArray, sql } from "drizzle-orm";
import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import pg from "pg";
import {
  PERMISSIONS,
  ROLE_NAMES,
  ROLE_PERMISSIONS,
  type RoleName,
} from "../rbac/permissions.js";
import * as schema from "./schema.js";
import {
  assertRoleName,
  type AppUser,
  type IdentityStore,
  type InviteUserInput,
  type UpsertFromIdentityInput,
  type UserStatus,
} from "./types.js";

type Db = NodePgDatabase<typeof schema>;

async function seedCatalog(db: Db): Promise<void> {
  for (const key of PERMISSIONS) {
    await db
      .insert(schema.permissions)
      .values({ key, description: key })
      .onConflictDoNothing({ target: schema.permissions.key });
  }

  for (const name of ROLE_NAMES) {
    await db
      .insert(schema.roles)
      .values({
        name,
        description:
          name === "admin" ? "Full access" : name === "viewer" ? "Read-only" : "Standard user",
      })
      .onConflictDoNothing({ target: schema.roles.name });
  }

  const allRoles = await db.select().from(schema.roles);
  const allPerms = await db.select().from(schema.permissions);
  const roleByName = new Map(allRoles.map((r) => [r.name, r]));
  const permByKey = new Map(allPerms.map((p) => [p.key, p]));

  for (const name of ROLE_NAMES) {
    const role = roleByName.get(name);
    if (!role) continue;
    for (const key of ROLE_PERMISSIONS[name]) {
      const perm = permByKey.get(key);
      if (!perm) continue;
      await db
        .insert(schema.rolePermissions)
        .values({ roleId: role.id, permissionId: perm.id })
        .onConflictDoNothing();
    }
  }
}

async function ensureTables(pool: pg.Pool): Promise<void> {
  await pool.query(`CREATE EXTENSION IF NOT EXISTS pgcrypto`).catch(() => undefined);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      cognito_sub text NOT NULL,
      status text NOT NULL DEFAULT 'active',
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      last_login_at timestamptz
    );
    CREATE UNIQUE INDEX IF NOT EXISTS users_cognito_sub_uidx ON users (cognito_sub);

    -- Drop legacy PII columns if an older schema was applied
    ALTER TABLE users DROP COLUMN IF EXISTS email;
    ALTER TABLE users DROP COLUMN IF EXISTS display_name;

    CREATE TABLE IF NOT EXISTS roles (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL,
      description text,
      created_at timestamptz NOT NULL DEFAULT now()
    );
    CREATE UNIQUE INDEX IF NOT EXISTS roles_name_uidx ON roles (name);

    CREATE TABLE IF NOT EXISTS permissions (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      key text NOT NULL,
      description text
    );
    CREATE UNIQUE INDEX IF NOT EXISTS permissions_key_uidx ON permissions (key);

    CREATE TABLE IF NOT EXISTS role_permissions (
      role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
      permission_id uuid NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
      PRIMARY KEY (role_id, permission_id)
    );

    CREATE TABLE IF NOT EXISTS user_roles (
      user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
      PRIMARY KEY (user_id, role_id)
    );
  `);
}

export class PostgresIdentityStore implements IdentityStore {
  readonly driver = "postgres" as const;
  private pool: pg.Pool;
  private db: Db;

  constructor(databaseUrl: string) {
    this.pool = new pg.Pool({
      connectionString: databaseUrl,
      max: 10,
      ssl:
        process.env.DATABASE_SSL === "0"
          ? false
          : {
              // RDS uses Amazon CA; strict verify optional via DATABASE_SSL_STRICT=1
              rejectUnauthorized: process.env.DATABASE_SSL_STRICT === "1",
            },
    });
    this.db = drizzle(this.pool, { schema });
  }

  async ready(): Promise<void> {
    await ensureTables(this.pool);
    await seedCatalog(this.db);
  }

  async close(): Promise<void> {
    await this.pool.end();
  }

  async countUsers(): Promise<number> {
    const res = await this.pool.query<{ count: string }>(`SELECT count(*)::text AS count FROM users`);
    return Number(res.rows[0]?.count ?? "0");
  }

  private async hydrate(userId: string): Promise<AppUser | null> {
    const rows = await this.db.select().from(schema.users).where(eq(schema.users.id, userId)).limit(1);
    const user = rows[0];
    if (!user) return null;

    const roleRows = await this.db
      .select({ name: schema.roles.name })
      .from(schema.userRoles)
      .innerJoin(schema.roles, eq(schema.userRoles.roleId, schema.roles.id))
      .where(eq(schema.userRoles.userId, userId));

    const roles = roleRows
      .map((r) => r.name)
      .filter((n): n is RoleName => (ROLE_NAMES as readonly string[]).includes(n));

    const permRows =
      roles.length === 0
        ? []
        : await this.db
            .select({ key: schema.permissions.key })
            .from(schema.userRoles)
            .innerJoin(schema.rolePermissions, eq(schema.userRoles.roleId, schema.rolePermissions.roleId))
            .innerJoin(schema.permissions, eq(schema.rolePermissions.permissionId, schema.permissions.id))
            .where(eq(schema.userRoles.userId, userId));

    return {
      id: user.id,
      cognitoSub: user.cognitoSub,
      status: user.status as UserStatus,
      roles,
      permissions: [...new Set(permRows.map((p) => p.key))].sort(),
      createdAt: user.createdAt,
      updatedAt: user.updatedAt,
      lastLoginAt: user.lastLoginAt,
    };
  }

  private async assignRoles(userId: string, roleNames: RoleName[]): Promise<void> {
    await this.db.delete(schema.userRoles).where(eq(schema.userRoles.userId, userId));
    if (!roleNames.length) return;
    const roleRows = await this.db
      .select()
      .from(schema.roles)
      .where(inArray(schema.roles.name, roleNames));
    if (!roleRows.length) return;
    await this.db.insert(schema.userRoles).values(roleRows.map((r) => ({ userId, roleId: r.id })));
  }

  async upsertFromIdentity(input: UpsertFromIdentityInput): Promise<AppUser> {
    const existing = await this.getByCognitoSub(input.cognitoSub);

    if (existing) {
      await this.db
        .update(schema.users)
        .set({
          status: existing.status === "invited" ? "active" : existing.status,
          updatedAt: sql`now()`,
          lastLoginAt: input.touchLogin ? sql`now()` : existing.lastLoginAt,
        })
        .where(eq(schema.users.id, existing.id));
      return (await this.hydrate(existing.id))!;
    }

    const roles = input.initialRoles?.length ? input.initialRoles : (["member"] as RoleName[]);
    const inserted = await this.db
      .insert(schema.users)
      .values({
        cognitoSub: input.cognitoSub,
        status: "active",
        lastLoginAt: input.touchLogin ? new Date() : null,
      })
      .returning({ id: schema.users.id });

    const id = inserted[0]!.id;
    await this.assignRoles(id, roles.map(assertRoleName));
    return (await this.hydrate(id))!;
  }

  async createInvitedUser(input: InviteUserInput): Promise<AppUser> {
    if (await this.getByCognitoSub(input.cognitoSub)) throw new Error("User already exists");
    const roles = (input.roles.length ? input.roles : (["member"] as RoleName[])).map(assertRoleName);

    const inserted = await this.db
      .insert(schema.users)
      .values({
        cognitoSub: input.cognitoSub,
        status: "invited",
      })
      .returning({ id: schema.users.id });

    const id = inserted[0]!.id;
    await this.assignRoles(id, roles);
    return (await this.hydrate(id))!;
  }

  async getById(id: string): Promise<AppUser | null> {
    return this.hydrate(id);
  }

  async getByCognitoSub(sub: string): Promise<AppUser | null> {
    const rows = await this.db
      .select({ id: schema.users.id })
      .from(schema.users)
      .where(eq(schema.users.cognitoSub, sub))
      .limit(1);
    return rows[0] ? this.hydrate(rows[0].id) : null;
  }

  async listUsers(): Promise<AppUser[]> {
    const rows = await this.db.select({ id: schema.users.id }).from(schema.users);
    const users = await Promise.all(rows.map((r) => this.hydrate(r.id)));
    return users
      .filter((u): u is AppUser => Boolean(u))
      .sort((a, b) => a.cognitoSub.localeCompare(b.cognitoSub));
  }

  async setStatus(id: string, status: UserStatus): Promise<AppUser> {
    await this.db
      .update(schema.users)
      .set({ status, updatedAt: sql`now()` })
      .where(eq(schema.users.id, id));
    const user = await this.hydrate(id);
    if (!user) throw new Error("User not found");
    return user;
  }

  async setRoles(id: string, roles: RoleName[]): Promise<AppUser> {
    await this.assignRoles(id, roles.map(assertRoleName));
    await this.db.update(schema.users).set({ updatedAt: sql`now()` }).where(eq(schema.users.id, id));
    const user = await this.hydrate(id);
    if (!user) throw new Error("User not found");
    return user;
  }

  async deleteUser(id: string): Promise<void> {
    await this.db.delete(schema.users).where(eq(schema.users.id, id));
  }

  async listRoles() {
    return ROLE_NAMES.map((name) => ({
      name,
      description: name === "admin" ? "Full access" : name === "viewer" ? "Read-only" : "Standard user",
      permissions: [...ROLE_PERMISSIONS[name]],
    }));
  }
}
