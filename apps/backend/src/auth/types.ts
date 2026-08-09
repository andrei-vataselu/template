import type { JWTPayload } from "jose";
import type { AppUser } from "../db/types.js";

export type CognitoAccessTokenClaims = JWTPayload & {
  token_use?: string;
  client_id?: string;
  username?: string;
  "cognito:groups"?: string[];
  scope?: string;
};

export type AuthenticatedUser = {
  sub: string;
  username: string | undefined;
  groups: string[];
  scope: string[];
  tokenExp: number | undefined;
};

declare global {
  namespace Express {
    interface Request {
      user?: AuthenticatedUser;
      accessToken?: string;
      appUser?: AppUser;
    }
  }
}

export {};
