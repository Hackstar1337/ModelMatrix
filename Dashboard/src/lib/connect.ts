import { api, post, query } from "./api";

export type ConnectTargetId = "kilo" | "opencode" | "manual";

export interface ConnectProfile {
  key: string;
  profile: string;
  display_name: string;
  model_id: string;
  runtime: string;
  host?: string;
  readiness: string;
  context?: number | null;
}

export interface ConnectRelay {
  base_url: string;
  server_root: string;
  listening: boolean;
  error?: string;
}

export interface ConnectProfilesPayload {
  profiles: ConnectProfile[];
  relay: ConnectRelay;
}

export interface ConnectTarget {
  id: "kilo" | "opencode";
  name: string;
  installed: boolean;
  qualified: boolean;
  version?: string;
  path?: string;
  config_path?: string;
  reason?: string;
  reload_note?: string;
}

export interface ConnectDetails {
  profile: string;
  display_name: string;
  model_id: string;
  provider: string;
  base_url: string;
  server_root: string;
  model_list_url: string;
  chat_url: string;
  api_key_requirement: "required" | "not_required" | "not_configured" | string;
  credential_kind?: string;
  readiness: string;
  context?: number | null;
  capabilities: { chat: boolean; tools: string; images: string; embeddings: string };
  connection_id?: string;
  summary: string;
  request_example: string;
  notes: string[];
}

export interface ConnectConnection {
  id: string;
  profile_key: string;
  profile: string;
  display_name: string;
  model_id: string;
  target: ConnectTargetId;
  provider_id: string;
  model_key: string;
  base_url: string;
  state: string;
  configured: boolean;
  api_tested: boolean;
  client_verified: boolean;
  reload_required: boolean;
  readiness: string;
  config_path?: string;
  message?: string;
  operation_id?: string;
  created_at?: string;
}

export interface ConnectPlan {
  id: string;
  expires_at?: string;
  profile_key: string;
  target: ConnectTargetId;
  title: string;
  config_path?: string;
  target_version?: string;
  provider_id: string;
  model_key: string;
  base_url: string;
  model_id: string;
  make_default: boolean;
  credential_storage: string;
  changes: string[];
  notes: string[];
  recovery: string;
}

export interface ConnectSecret {
  key: string;
  warning: string;
}

export interface ConnectListPayload {
  connections: ConnectConnection[];
  operations?: unknown[];
}

export const connectProfiles = (signal?: AbortSignal) => api<ConnectProfilesPayload>("/api/connect/profiles", { signal });
export const connectTargets = (signal?: AbortSignal) => api<{ targets: ConnectTarget[] }>("/api/connect/targets", { signal });
export const connectDetails = (profile: string, connection?: string, signal?: AbortSignal) =>
  api<ConnectDetails>(`/api/connect/details${query({ profile, connection })}`, { signal });
export const connectList = (signal?: AbortSignal) => api<ConnectListPayload>("/api/connect/list", { signal });
export const connectPlan = (profile: string, target: ConnectTargetId, makeDefault = false) =>
  post<{ plan: ConnectPlan; existing?: boolean }>("/api/connect/plan", { profile, target, make_default: makeDefault });
export const connectApply = (plan_id: string) => post<{ connection: ConnectConnection; operation_id?: string; existing?: boolean }>("/api/connect/apply", { plan_id, approved: true });
export const connectVerify = (id: string) => post<{ connection: ConnectConnection; message: string }>("/api/connect/verify", { id });
export const connectDisconnect = (id: string) =>
  post<{ connection: ConnectConnection; message: string }>("/api/connect/disconnect", { id, remove_config: true, approved: true });
export const connectUndo = (id: string) => post<{ connection: ConnectConnection; message: string }>("/api/connect/undo", { id, approved: true });
/** Secret retrieval is intentionally isolated: callers must make an explicit, user-visible action. */
export const connectSecret = (id: string) => post<ConnectSecret>("/api/connect/key", { id, approved: true });
