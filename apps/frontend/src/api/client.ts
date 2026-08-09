import { getValidAccessToken, logoutLocal } from "../auth/cognitoAuth";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code?: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

type ApiOptions = RequestInit & {
  /** Attach Cognito access token when available / required */
  auth?: boolean;
};

export async function apiFetch<T>(path: string, options: ApiOptions = {}): Promise<T> {
  const headers = new Headers(options.headers);
  if (!headers.has("Accept")) {
    headers.set("Accept", "application/json");
  }

  if (options.auth) {
    const token = await getValidAccessToken();
    if (!token) {
      logoutLocal();
      throw new ApiError("Not authenticated", 401, "missing_token");
    }
    headers.set("Authorization", `Bearer ${token}`);
  }

  const res = await fetch(path, { ...options, headers });

  if (res.status === 401 && options.auth) {
    logoutLocal();
  }

  const contentType = res.headers.get("content-type") ?? "";
  const body = contentType.includes("application/json")
    ? ((await res.json()) as { error?: string; code?: string })
    : null;

  if (!res.ok) {
    throw new ApiError(body?.error ?? `Request failed (${res.status})`, res.status, body?.code);
  }

  return body as T;
}
