import { Router } from "express";
import rateLimit from "express-rate-limit";
import { z } from "zod";
import { requireAuth, requirePermission } from "../auth/middleware.js";
import { getIdentityStore } from "../db/client.js";
import {
  inviteUser,
  parseAssignableRoles,
  removeUser,
  setUserDisabled,
  updateUserRoles,
} from "../services/users.js";

export const adminUsersRouter = Router();

adminUsersRouter.use(requireAuth);

/** Per-caller invite cap (after auth so we can key by Cognito sub). */
const inviteLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.user!.sub,
  // Sub is always set after requireAuth; do not fall back to IP.
  validate: { keyGeneratorIpFallback: false },
  message: { ok: false, error: "Too many invite attempts", code: "rate_limited" },
});

adminUsersRouter.get("/admin/roles", requirePermission("roles:read"), async (_req, res, next) => {
  try {
    const roles = await getIdentityStore().listRoles();
    res.json({ ok: true, roles });
  } catch (err) {
    next(err);
  }
});

adminUsersRouter.get("/admin/users", requirePermission("users:read"), async (_req, res, next) => {
  try {
    const users = await getIdentityStore().listUsers();
    res.json({
      ok: true,
      users: users.map((u) => ({
        id: u.id,
        cognitoSub: u.cognitoSub,
        status: u.status,
        roles: u.roles,
        permissions: u.permissions,
        lastLoginAt: u.lastLoginAt,
        createdAt: u.createdAt,
      })),
    });
  } catch (err) {
    next(err);
  }
});

const inviteSchema = z.object({
  email: z.string().email().max(320),
  roles: z.array(z.string()).max(10).optional(),
});

const rolesSchema = z.object({
  roles: z.array(z.string()).min(1).max(10),
});

adminUsersRouter.post(
  "/admin/users",
  inviteLimiter,
  requirePermission("users:invite"),
  async (req, res, next) => {
    try {
      const body = inviteSchema.parse(req.body);
      // Email is passed to Cognito only; local row stores cognitoSub + roles.
      const user = await inviteUser(body.email, parseAssignableRoles(body.roles ?? ["member"]));
      res.status(201).json({
        ok: true,
        user: {
          id: user.id,
          cognitoSub: user.cognitoSub,
          status: user.status,
          roles: user.roles,
          permissions: user.permissions,
        },
      });
    } catch (err) {
      next(err);
    }
  },
);

adminUsersRouter.patch(
  "/admin/users/:id/roles",
  requirePermission("users:write"),
  async (req, res, next) => {
    try {
      const body = rolesSchema.parse(req.body);
      const user = await updateUserRoles(req.params.id, body.roles);
      res.json({ ok: true, user });
    } catch (err) {
      next(err);
    }
  },
);

adminUsersRouter.post(
  "/admin/users/:id/disable",
  requirePermission("users:write"),
  async (req, res, next) => {
    try {
      const user = await setUserDisabled(req.params.id, true);
      res.json({ ok: true, user });
    } catch (err) {
      next(err);
    }
  },
);

adminUsersRouter.post(
  "/admin/users/:id/enable",
  requirePermission("users:write"),
  async (req, res, next) => {
    try {
      const user = await setUserDisabled(req.params.id, false);
      res.json({ ok: true, user });
    } catch (err) {
      next(err);
    }
  },
);

adminUsersRouter.delete(
  "/admin/users/:id",
  requirePermission("users:delete"),
  async (req, res, next) => {
    try {
      await removeUser(req.params.id);
      res.status(204).send();
    } catch (err) {
      next(err);
    }
  },
);
