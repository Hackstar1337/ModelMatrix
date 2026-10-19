// API client for the local ModelMatrix controller (same origin).

export class ApiError extends Error {
  status: number;
  code?: string;
  constructor(status: number, message: string, code?: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

type Options = { method?: string; body?: unknown; signal?: AbortSignal };

export async function api<T = any>(path: string, options: Options = {}): Promise<T> {
  const { method = options.body !== undefined ? "POST" : "GET", body, signal } = options;
  let response: Response;
  try {
    response = await fetch(path, {
      method,
      signal,
      cache: "no-store",
      credentials: "same-origin",
      headers: body !== undefined ? { "Content-Type": "application/json" } : undefined,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch (error) {
    if ((error as Error).name === "AbortError") throw error;
    throw new ApiError(0, "Controller not reachable. Is ModelMatrix running?", "offline");
  }
  const text = await response.text();
  let data: any = {};
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = { raw: text };
    }
  }
  if (!response.ok) {
    const message = data?.message || data?.error || response.statusText || `HTTP ${response.status}`;
    throw new ApiError(response.status, String(message), data?.error);
  }
  return data as T;
}

export const post = <T = any>(path: string, body: unknown = {}) => api<T>(path, { method: "POST", body });

export function remote(gateway: string, path: string) {
  return `/api/remote/${encodeURIComponent(gateway)}${path}`;
}

export function query(params: Record<string, string | number | undefined | null>) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== "") search.set(key, String(value));
  }
  const text = search.toString();
  return text ? `?${text}` : "";
}
