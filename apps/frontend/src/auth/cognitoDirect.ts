import {
  AuthenticationDetails,
  CognitoUser,
  CognitoUserAttribute,
  CognitoUserPool,
  CognitoUserSession,
} from "amazon-cognito-identity-js";
import { loadCognitoConfig } from "./config";
import { saveSession, type StoredSession } from "./session";

function pool(): CognitoUserPool {
  const cfg = loadCognitoConfig();
  if (!cfg) throw new Error("Cognito is not configured");
  return new CognitoUserPool({
    UserPoolId: cfg.userPoolId,
    ClientId: cfg.clientId,
  });
}

function cognitoUser(email: string): CognitoUser {
  return new CognitoUser({ Username: email.trim().toLowerCase(), Pool: pool() });
}

function sessionFromCognito(session: CognitoUserSession): StoredSession {
  const access = session.getAccessToken();
  const id = session.getIdToken();
  const refresh = session.getRefreshToken();
  return {
    accessToken: access.getJwtToken(),
    idToken: id.getJwtToken(),
    refreshToken: refresh.getToken(),
    expiresAt: access.getExpiration() * 1000,
    scope: String((access.payload as { scope?: string }).scope ?? ""),
    tokenType: "Bearer",
  };
}

export type AuthChallenge =
  | { type: "done"; session: StoredSession }
  | { type: "confirm_signup"; email: string }
  | { type: "mfa_totp"; user: CognitoUser }
  | { type: "mfa_setup"; user: CognitoUser; secretCode: string }
  | { type: "new_password"; user: CognitoUser };

function mapError(err: unknown): Error {
  if (err && typeof err === "object" && "message" in err) {
    return new Error(String((err as { message: string }).message));
  }
  return new Error("Authentication failed");
}

export function signUp(email: string, password: string): Promise<{ userConfirmed: boolean }> {
  return new Promise((resolve, reject) => {
    const attributeList = [
      new CognitoUserAttribute({ Name: "email", Value: email.trim().toLowerCase() }),
    ];
    pool().signUp(email.trim().toLowerCase(), password, attributeList, [], (err, result) => {
      if (err || !result) {
        reject(mapError(err));
        return;
      }
      resolve({ userConfirmed: result.userConfirmed });
    });
  });
}

export function confirmSignUp(email: string, code: string): Promise<void> {
  return new Promise((resolve, reject) => {
    cognitoUser(email).confirmRegistration(code.trim(), true, (err) => {
      if (err) reject(mapError(err));
      else resolve();
    });
  });
}

export function resendConfirmation(email: string): Promise<void> {
  return new Promise((resolve, reject) => {
    cognitoUser(email).resendConfirmationCode((err) => {
      if (err) reject(mapError(err));
      else resolve();
    });
  });
}

export function forgotPassword(email: string): Promise<void> {
  return new Promise((resolve, reject) => {
    cognitoUser(email).forgotPassword({
      onSuccess: () => resolve(),
      onFailure: (err) => reject(mapError(err)),
    });
  });
}

export function confirmForgotPassword(email: string, code: string, newPassword: string): Promise<void> {
  return new Promise((resolve, reject) => {
    cognitoUser(email).confirmPassword(code.trim(), newPassword, {
      onSuccess: () => resolve(),
      onFailure: (err) => reject(mapError(err)),
    });
  });
}

export function signIn(email: string, password: string): Promise<AuthChallenge> {
  const user = cognitoUser(email);
  const auth = new AuthenticationDetails({
    Username: email.trim().toLowerCase(),
    Password: password,
  });

  return new Promise((resolve, reject) => {
    user.authenticateUser(auth, {
      onSuccess: (session) => {
        const stored = sessionFromCognito(session);
        saveSession(stored);
        resolve({ type: "done", session: stored });
      },
      onFailure: (err) => {
        const name = (err as { name?: string; code?: string }).code ?? (err as { name?: string }).name;
        if (name === "UserNotConfirmedException") {
          resolve({ type: "confirm_signup", email: email.trim().toLowerCase() });
          return;
        }
        reject(mapError(err));
      },
      totpRequired: () => resolve({ type: "mfa_totp", user }),
      mfaSetup: () => {
        user.associateSoftwareToken({
          associateSecretCode: (secretCode) => resolve({ type: "mfa_setup", user, secretCode }),
          onFailure: (err) => reject(mapError(err)),
        });
      },
      newPasswordRequired: () => resolve({ type: "new_password", user }),
    });
  });
}

export function completeNewPassword(user: CognitoUser, newPassword: string): Promise<AuthChallenge> {
  return new Promise((resolve, reject) => {
    user.completeNewPasswordChallenge(
      newPassword,
      {},
      {
        onSuccess: (session) => {
          const stored = sessionFromCognito(session);
          saveSession(stored);
          resolve({ type: "done", session: stored });
        },
        onFailure: (err) => reject(mapError(err)),
        totpRequired: () => resolve({ type: "mfa_totp", user }),
        mfaSetup: () => {
          user.associateSoftwareToken({
            associateSecretCode: (secretCode) => resolve({ type: "mfa_setup", user, secretCode }),
            onFailure: (err) => reject(mapError(err)),
          });
        },
      },
    );
  });
}

export function verifyTotp(user: CognitoUser, code: string): Promise<StoredSession> {
  return new Promise((resolve, reject) => {
    user.sendMFACode(
      code.trim(),
      {
        onSuccess: (session) => {
          const stored = sessionFromCognito(session);
          saveSession(stored);
          resolve(stored);
        },
        onFailure: (err) => reject(mapError(err)),
      },
      "SOFTWARE_TOKEN_MFA",
    );
  });
}

export function verifyTotpSetup(user: CognitoUser, code: string): Promise<StoredSession> {
  return new Promise((resolve, reject) => {
    user.verifySoftwareToken(code.trim(), "Authenticator", {
      onSuccess: (session) => {
        const stored = sessionFromCognito(session);
        saveSession(stored);
        resolve(stored);
      },
      onFailure: (err) => reject(mapError(err)),
    });
  });
}
