const TE = new TextEncoder();

function toBase64Url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (let i = 0; i < view.length; i += 1) {
    binary += String.fromCharCode(view[i]!);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export function randomUrlSafe(byteLength = 32): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return toBase64Url(bytes);
}

export async function createPkceChallenge(): Promise<{ verifier: string; challenge: string }> {
  const verifier = randomUrlSafe(32);
  const digest = await crypto.subtle.digest("SHA-256", TE.encode(verifier));
  return { verifier, challenge: toBase64Url(digest) };
}
