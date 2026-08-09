import { Router } from "express";
import { requireAuth, requirePermission } from "../auth/middleware.js";

export const meRouter = Router();

meRouter.get("/me", requireAuth, (req, res) => {
  const appUser = req.appUser!;
  res.json({
    ok: true,
    identity: {
      sub: req.user!.sub,
      username: req.user!.username,
      cognitoGroups: req.user!.groups,
      scope: req.user!.scope,
    },
    user: {
      id: appUser.id,
      cognitoSub: appUser.cognitoSub,
      status: appUser.status,
      roles: appUser.roles,
      permissions: appUser.permissions,
      lastLoginAt: appUser.lastLoginAt,
    },
  });
});

meRouter.get("/admin/ping", requireAuth, requirePermission("admin:access"), (_req, res) => {
  res.json({
    ok: true,
    rbac: true,
    message: "Admin access granted via custom RBAC",
  });
});
