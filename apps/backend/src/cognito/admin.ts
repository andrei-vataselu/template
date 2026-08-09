import {
  AdminCreateUserCommand,
  AdminDeleteUserCommand,
  AdminDisableUserCommand,
  AdminEnableUserCommand,
  CognitoIdentityProviderClient,
  GetUserCommand,
  ListUsersCommand,
  UserNotFoundException,
  UsernameExistsException,
} from "@aws-sdk/client-cognito-identity-provider";
import { config } from "../config.js";

export type CognitoProfile = {
  username: string;
  sub: string;
  email: string;
};

let client: CognitoIdentityProviderClient | null = null;

function getClient(): CognitoIdentityProviderClient {
  if (!client) {
    if (!config.cognito.region) {
      throw new Error("COGNITO_REGION is required for Cognito Admin APIs");
    }
    client = new CognitoIdentityProviderClient({ region: config.cognito.region });
  }
  return client;
}

function attrMap(attrs: Array<{ Name?: string; Value?: string }> | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  for (const a of attrs ?? []) {
    if (a.Name && a.Value !== undefined) out[a.Name] = a.Value;
  }
  return out;
}

/** Profile from access token — used ephemerally (never persisted). */
export async function getProfileFromAccessToken(accessToken: string): Promise<CognitoProfile> {
  const res = await getClient().send(new GetUserCommand({ AccessToken: accessToken }));
  const attrs = attrMap(res.UserAttributes);
  const sub = attrs.sub;
  const email = attrs.email;
  if (!sub || !email) {
    throw new Error("Cognito user is missing sub/email attributes");
  }
  return {
    username: res.Username ?? email,
    sub,
    email,
  };
}

export type InviteCognitoResult = {
  username: string;
  sub: string;
};

export async function adminInviteUser(email: string): Promise<InviteCognitoResult> {
  if (!config.cognito.userPoolId) {
    throw new Error("COGNITO_USER_POOL_ID is not configured");
  }
  const normalized = email.trim().toLowerCase();

  try {
    const res = await getClient().send(
      new AdminCreateUserCommand({
        UserPoolId: config.cognito.userPoolId,
        Username: normalized,
        DesiredDeliveryMediums: ["EMAIL"],
        UserAttributes: [
          { Name: "email", Value: normalized },
          { Name: "email_verified", Value: "true" },
        ],
      }),
    );
    const attrs = attrMap(res.User?.Attributes);
    const sub = attrs.sub;
    if (!sub) throw new Error("Cognito did not return user sub");
    return { username: res.User?.Username ?? normalized, sub };
  } catch (err) {
    if (err instanceof UsernameExistsException) {
      throw new Error("Cognito user already exists");
    }
    throw err;
  }
}

/** Resolve Cognito Username from sub without storing email locally. */
export async function adminUsernameBySub(cognitoSub: string): Promise<string> {
  if (!config.cognito.userPoolId) {
    throw new Error("COGNITO_USER_POOL_ID is not configured");
  }
  const res = await getClient().send(
    new ListUsersCommand({
      UserPoolId: config.cognito.userPoolId,
      Filter: `sub = "${cognitoSub.replace(/"/g, "")}"`,
      Limit: 1,
    }),
  );
  const username = res.Users?.[0]?.Username;
  if (!username) {
    throw Object.assign(new Error("Cognito user not found"), { code: "not_found", status: 404 });
  }
  return username;
}

export async function adminDisableBySub(cognitoSub: string): Promise<void> {
  const username = await adminUsernameBySub(cognitoSub);
  await getClient().send(
    new AdminDisableUserCommand({
      UserPoolId: config.cognito.userPoolId!,
      Username: username,
    }),
  );
}

export async function adminEnableBySub(cognitoSub: string): Promise<void> {
  const username = await adminUsernameBySub(cognitoSub);
  await getClient().send(
    new AdminEnableUserCommand({
      UserPoolId: config.cognito.userPoolId!,
      Username: username,
    }),
  );
}

export async function adminDeleteBySub(cognitoSub: string): Promise<void> {
  try {
    const username = await adminUsernameBySub(cognitoSub);
    await getClient().send(
      new AdminDeleteUserCommand({
        UserPoolId: config.cognito.userPoolId!,
        Username: username,
      }),
    );
  } catch (err) {
    if (err instanceof UserNotFoundException) return;
    const maybe = err as { code?: string; status?: number };
    if (maybe.code === "not_found") return;
    throw err;
  }
}

export async function adminDeleteUser(username: string): Promise<void> {
  if (!config.cognito.userPoolId) throw new Error("COGNITO_USER_POOL_ID is not configured");
  try {
    await getClient().send(
      new AdminDeleteUserCommand({
        UserPoolId: config.cognito.userPoolId,
        Username: username,
      }),
    );
  } catch (err) {
    if (err instanceof UserNotFoundException) return;
    throw err;
  }
}
