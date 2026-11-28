export const utf8 = (string: string) => new Uint8Array(new TextEncoder().encode(string));

export function fromBase64Url(value: string) {
  return Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), (byte) => byte.charCodeAt(0));
}

export function base64Url(value: Uint8Array) {
  return btoa(String.fromCharCode(...value)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export const randomToken = () => base64Url(crypto.getRandomValues(new Uint8Array(32)));

export async function sha256(data: Uint8Array<ArrayBuffer>) {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return Array.from(hash, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function canonicalBase64(value: unknown, length: number): value is string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value) ||
      value.length !== Math.ceil(length * 4 / 3)) return false;
  return base64Url(fromBase64Url(value)) === value;
}
