function requiredWhenAuth(name: string, value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

const region = requiredWhenAuth("COGNITO_REGION", process.env.COGNITO_REGION ?? process.env.AWS_REGION);
const userPoolId = requiredWhenAuth("COGNITO_USER_POOL_ID", process.env.COGNITO_USER_POOL_ID);
const clientId = requiredWhenAuth("COGNITO_CLIENT_ID", process.env.COGNITO_CLIENT_ID);
const databaseUrl = process.env.DATABASE_URL?.trim() || undefined;

export const config = {
  port: Number(process.env.PORT ?? 3000),
  environment: process.env.APP_ENV ?? "dev",
  appName: process.env.APP_NAME ?? "template",
  nodeEnv: process.env.NODE_ENV ?? "development",
  databaseUrl,
  allowedOrigins: (process.env.ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
  cognito: {
    region,
    userPoolId,
    clientId,
    get configured(): boolean {
      return Boolean(region && userPoolId && clientId);
    },
    get issuer(): string | null {
      if (!region || !userPoolId) return null;
      return `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`;
    },
    get jwksUrl(): URL | null {
      const issuer = this.issuer;
      if (!issuer) return null;
      return new URL(`${issuer}/.well-known/jwks.json`);
    },
  },
} as const;
