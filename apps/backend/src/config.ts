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
  /**
   * Trusted proxy hops in front of Express. Must match the real chain or
   * req.ip (rate-limit key) resolves to a proxy instead of the client:
   * CloudFront -> ALB -> nginx gateway = 3 on AWS, 1 behind a lone gateway.
   */
  trustProxyHops: Math.max(0, Number(process.env.TRUST_PROXY_HOPS ?? 1) || 0),
  allowedOrigins: (process.env.ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
  /** When true, Cognito users without a local row are rejected (must be invited). */
  inviteOnly: ["1", "true", "yes"].includes((process.env.INVITE_ONLY ?? "").trim().toLowerCase()),
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
