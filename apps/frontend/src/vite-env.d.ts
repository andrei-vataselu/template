/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_COGNITO_REGION: string;
  readonly VITE_COGNITO_USER_POOL_ID: string;
  readonly VITE_COGNITO_CLIENT_ID: string;
  /** Hosted UI domain prefix (module output), e.g. popo-dev-a1b2c3 */
  readonly VITE_COGNITO_DOMAIN: string;
  /** Absolute API base URL (empty = same-origin /api) */
  readonly VITE_API_BASE_URL?: string;
  /** When "1", hide self-signup CTAs (invite-only deploys). */
  readonly VITE_INVITE_ONLY?: string;
  readonly VITE_APP_NAME?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
