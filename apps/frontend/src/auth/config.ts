export type CognitoPublicConfig = {
  region: string;
  userPoolId: string;
  clientId: string;
  domainPrefix: string;
  authority: string;
  hostedUiBase: string;
  redirectUri: string;
  logoutUri: string;
  scopes: string[];
};

function trim(value: string | undefined): string {
  return (value ?? "").trim();
}

/** Prefer HTTPS everywhere except local Vite / localhost previews. */
export function ensureHttpsOrigin(): string {
  const { protocol, host, hostname, origin } = window.location;
  if (hostname === "localhost" || hostname === "127.0.0.1") {
    return origin;
  }
  if (protocol !== "https:") {
    const httpsUrl = `https://${host}${window.location.pathname}${window.location.search}${window.location.hash}`;
    window.location.replace(httpsUrl);
    return `https://${host}`;
  }
  return origin;
}

export function loadCognitoConfig(): CognitoPublicConfig | null {
  const region = trim(import.meta.env.VITE_COGNITO_REGION);
  const userPoolId = trim(import.meta.env.VITE_COGNITO_USER_POOL_ID);
  const clientId = trim(import.meta.env.VITE_COGNITO_CLIENT_ID);
  const domainPrefix = trim(import.meta.env.VITE_COGNITO_DOMAIN);

  if (!region || !userPoolId || !clientId || !domainPrefix) {
    return null;
  }

  const origin = ensureHttpsOrigin();

  // Custom auth domain is a FQDN (contains a dot). Cognito prefix domains do not.
  const hostedUiBase = domainPrefix.includes(".")
    ? `https://${domainPrefix}`
    : `https://${domainPrefix}.auth.${region}.amazoncognito.com`;

  return {
    region,
    userPoolId,
    clientId,
    domainPrefix,
    authority: `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`,
    hostedUiBase,
    redirectUri: `${origin}/callback`,
    logoutUri: `${origin}/logout`,
    scopes: ["openid", "email", "profile"],
  };
}
