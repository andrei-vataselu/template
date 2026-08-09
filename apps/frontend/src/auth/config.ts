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

export function loadCognitoConfig(): CognitoPublicConfig | null {
  const region = trim(import.meta.env.VITE_COGNITO_REGION);
  const userPoolId = trim(import.meta.env.VITE_COGNITO_USER_POOL_ID);
  const clientId = trim(import.meta.env.VITE_COGNITO_CLIENT_ID);
  const domainPrefix = trim(import.meta.env.VITE_COGNITO_DOMAIN);

  if (!region || !userPoolId || !clientId || !domainPrefix) {
    return null;
  }

  const origin = window.location.origin;

  return {
    region,
    userPoolId,
    clientId,
    domainPrefix,
    authority: `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`,
    hostedUiBase: `https://${domainPrefix}.auth.${region}.amazoncognito.com`,
    redirectUri: `${origin}/callback`,
    logoutUri: `${origin}/logout`,
    scopes: ["openid", "email", "profile"],
  };
}
