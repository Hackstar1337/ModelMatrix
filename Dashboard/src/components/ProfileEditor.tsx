import { useEffect, useMemo, useRef, useState } from "react";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { api, post } from "../lib/api";
import { useApp } from "../lib/state";
import type { ProfileDocument, ProfileTemplate, RuntimeInfo } from "../lib/types";
import { Modal, Notice, Switch } from "./ui";

const coreFields: { key: string; label: string; hint?: string; placeholder?: string }[] = [
  { key: "DISPLAY_NAME", label: "Display name", placeholder: "Qwen 3 8B" },
  { key: "REQUEST_MODEL", label: "Request model", hint: "Model name clients send", placeholder: "qwen3:8b" },
  { key: "SERVER_MODEL_ID", label: "Server model ID", hint: "ID the server reports (optional)" },
  { key: "PORT", label: "Port", hint: "Leave empty to use the port in Base URL", placeholder: "From Base URL" },
  { key: "BASE_URL", label: "Base URL", hint: "OpenAI-compatible base, e.g. http://127.0.0.1:8080/v1" },
  { key: "MODEL_PATH", label: "Model path", hint: "Weights file or folder. Not needed for Ollama, LM Studio or external servers" },
];

/** Same rules as the controller (RuntimeCatalog.launchMode / ControllerProfile.healthcheckMode). */
const launchModes = ["adapter", "command", "external"];
const launchLabels: Record<string, string> = {
  adapter: "adapter: ModelMatrix starts it",
  command: "command: runs START_COMMAND",
  external: "external: already running",
};
const launchHints: Record<string, string> = {
  adapter: "ModelMatrix starts and stops this server for you.",
  command: "Runs START_COMMAND (add it under Other settings) and STOP_COMMAND if set.",
  external: "ModelMatrix only connects. Start and stop the server yourself (for example in LM Studio).",
};
/** Runtimes Controller/start-model-mac.sh can launch by itself. */
const nativeLaunchers = new Set(["llama.cpp", "mlx", "rvllm-mlx", "vllm-mlx", "ollama", "vllm", "sglang", "tgi", "llama-cpp-python"]);
function adapterHint(runtimeId: string, hasServerBin: boolean) {
  if (nativeLaunchers.has(runtimeId)) return launchHints.adapter;
  if (hasServerBin) return "ModelMatrix starts SERVER_BIN with the arguments in SERVER_ARGS_JSON.";
  return "This runtime has no built-in launcher: add START_COMMAND (or SERVER_BIN plus SERVER_ARGS_JSON) under Other settings, or start the server yourself first.";
}
const healthModes = ["openai-models", "http-200", "disabled"];
const healthLabels: Record<string, string> = {
  "openai-models": "openai-models: model is listed",
  "http-200": "http-200: a URL answers OK",
  disabled: "disabled: don't check",
};
const healthHints: Record<string, string> = {
  "openai-models": "Ready when the server lists the Server model ID (or Request model) at /v1/models.",
  "http-200": "Ready when HEALTHCHECK_URL (add it under Other settings) answers with success.",
  disabled: "Never checked, so the model can show as ready before it really is.",
};
function normalizeHealth(value?: string) {
  const v = (value ?? "").toLowerCase();
  if (v === "http-200" || v === "http200") return "http-200";
  if (v === "disabled" || v === "off" || v === "none") return "disabled";
  return "openai-models";
}
const hidden = new Set(["RUNTIME", "CAPTURE_MODE", "PROFILE_NAME", "LAUNCH_MODE", "HEALTHCHECK_MODE", ...coreFields.map((f) => f.key)]);

export function ProfileEditor({ profile, onClose, onSaved }: { profile?: string; onClose: () => void; onSaved: (name: string) => void }) {
  const { settings, toast, refreshStatus } = useApp();
  const creating = !profile;
  const [name, setName] = useState(profile ?? "");
  const [values, setValues] = useState<Record<string, string>>({ RUNTIME: "ollama" });
  const [text, setText] = useState("");
  const [tab, setTab] = useState<"form" | "raw">("form");
  const [doc, setDoc] = useState<ProfileDocument | null>(null);
  const [runtimes, setRuntimes] = useState<RuntimeInfo[]>([]);
  const [templates, setTemplates] = useState<ProfileTemplate[]>([]);
  const [extra, setExtra] = useState<{ key: string; value: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api<{ runtimes: RuntimeInfo[]; templates: ProfileTemplate[] }>("/api/profiles/runtimes")
      .then((r) => {
        setRuntimes(r.runtimes ?? []);
        setTemplates(r.templates ?? []);
        if (creating && r.templates?.[0]) applyTemplate(r.templates[0]);
      })
      .catch(() => undefined);
    if (profile) {
      api<ProfileDocument>(`/api/profiles/document?profile=${encodeURIComponent(profile)}`)
        .then((d) => {
          setDoc(d);
          setText(d.text);
          load(d.values);
        })
        .catch((e) => setError(e.message));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [profile]);

  function load(next: Record<string, string>) {
    const copy = { ...next };
    delete copy.PROFILE_NAME;
    setValues(copy);
    setExtra(Object.entries(copy).filter(([k]) => !hidden.has(k)).map(([key, value]) => ({ key, value })));
  }

  // Remember the ID a template filled in, so picking another template replaces
  // it, while an ID the user typed is kept.
  const autoName = useRef("");
  function applyTemplate(template: ProfileTemplate) {
    load(template.values);
    if (!creating) return;
    const suggested = template.id.replace(/-profile$/, "").replace(/[^a-z0-9-]/gi, "-").toLowerCase();
    setName((current) => {
      if (current && current !== autoName.current) return current;
      autoName.current = suggested;
      return suggested;
    });
  }

  const merged = useMemo(() => {
    const result: Record<string, string> = {};
    for (const [k, v] of Object.entries(values)) if (hidden.has(k) && v !== "") result[k] = v;
    for (const { key, value } of extra) if (key.trim()) result[key.trim().toUpperCase()] = value;
    return result;
  }, [values, extra]);

  const set = (key: string, value: string) => setValues((v) => ({ ...v, [key]: value }));

  const runtimeId = (values.RUNTIME ?? "").toLowerCase();
  const runtimeDefault = runtimes.find((r) => r.id === runtimeId)?.launch_mode ?? "adapter";
  const hasStartCommand = extra.some((r) => r.key.trim().toUpperCase() === "START_COMMAND" && r.value.trim() !== "");
  const hasExtra = (key: string) => extra.some((r) => r.key.trim().toUpperCase() === key && r.value.trim() !== "");
  const hasServerBin = hasExtra("SERVER_BIN") && hasExtra("SERVER_ARGS_JSON");
  const launchValue = (values.LAUNCH_MODE ?? "").toLowerCase();
  const effectiveLaunch = hasStartCommand ? "command" : launchModes.includes(launchValue) ? launchValue : runtimeDefault;
  const health = normalizeHealth(values.HEALTHCHECK_MODE);
  const portNumber = Number(values.PORT ?? "");
  const portOk = /^\d+$/.test(values.PORT ?? "") && portNumber > 0 && portNumber < 65536;
  const captureOn = values.CAPTURE_MODE === "1";
  const captureBlocked =
    runtimeId === "ollama"
      ? "Not available for Ollama, because Ollama always uses its own port. Point your apps at the relay address in Settings instead."
      : effectiveLaunch === "external"
        ? "Not available for servers you run yourself. Point your apps at the relay address in Settings instead."
        : !portOk
          ? "Fill in Port to use capture mode."
          : null;

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const id = name.trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) throw new Error("Profile ID can use letters, numbers, dot, dash and underscore.");
      const body: Record<string, unknown> = { profile: id, create: creating };
      if (!creating) body.original_profile = profile;
      if (tab === "raw") body.text = text;
      else body.values = merged;
      await post("/api/profiles/save", body);
      toast(`${creating ? "Created" : "Saved"} ${id}`, "ok");
      await refreshStatus();
      onSaved(id);
      onClose();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      title={creating ? "New model profile" : `Edit ${profile}`}
      onClose={onClose}
      footer={
        <>
          {error && <span className="red grow" style={{ fontSize: 13 }}>{error}</span>}
          <button className="btn ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn primary" onClick={save} disabled={busy}>
            {busy && <Loader2 size={14} className="spin" />} {creating ? "Create profile" : "Save changes"}
          </button>
        </>
      }
    >
      <div className="stack">
        {doc?.running && <Notice kind="warn">This model is running. Changes apply the next time it starts (use Restart).</Notice>}
        <div className="row between wrap">
          <div className="seg sm">
            <button className={tab === "form" ? "on" : ""} onClick={() => setTab("form")}>
              Form
            </button>
            <button
              className={tab === "raw" ? "on" : ""}
              onClick={() => {
                if (tab === "form") setText(Object.entries(merged).map(([k, v]) => `${k}=${/[\s#"']/.test(v) ? JSON.stringify(v) : v}`).join("\n") + "\n");
                setTab("raw");
              }}
            >
              Raw file
            </button>
          </div>
          {creating && templates.length > 0 && (
            <div className="row">
              <span className="muted" style={{ fontSize: 12 }}>
                Start from
              </span>
              <select className="select" onChange={(e) => applyTemplate(templates.find((t) => t.id === e.target.value)!)} defaultValue={templates[0]?.id}>
                {templates.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.label}
                  </option>
                ))}
              </select>
            </div>
          )}
        </div>

        <div className="form-grid">
          <div className="field">
            <label>Profile ID</label>
            <input className="input mono" value={name} onChange={(e) => setName(e.target.value)} placeholder="qwen3-8b" />
            <span className="hint">{creating ? "File name in your profiles folder" : "Renaming moves the file"}</span>
          </div>
          <div className="field">
            <label>Runtime</label>
            <select className="select" style={{ width: "100%" }} value={values.RUNTIME ?? ""} onChange={(e) => set("RUNTIME", e.target.value)} disabled={tab === "raw"}>
              {!runtimes.some((r) => r.id === values.RUNTIME) && values.RUNTIME && <option value={values.RUNTIME}>{values.RUNTIME}</option>}
              {runtimes.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.label}
                </option>
              ))}
            </select>
          </div>
        </div>

        {tab === "raw" ? (
          <div className="field">
            <label>{doc?.file ?? "profile.env"}</label>
            <textarea className="textarea" value={text} onChange={(e) => setText(e.target.value)} spellCheck={false} />
            <span className="hint">KEY=value lines. Saved exactly as written after validation.</span>
          </div>
        ) : (
          <>
            <div className="form-grid">
              {coreFields.map((f) => (
                <div className="field" key={f.key}>
                  <label>{f.label}</label>
                  <input className="input mono" value={values[f.key] ?? ""} placeholder={f.placeholder} onChange={(e) => set(f.key, e.target.value)} />
                  {f.hint && <span className="hint">{f.hint}</span>}
                </div>
              ))}
              <div className="field">
                <label>Launch mode</label>
                <select className="select" style={{ width: "100%" }} value={launchValue} onChange={(e) => set("LAUNCH_MODE", e.target.value)}>
                  <option value="">Default for this runtime ({runtimeDefault})</option>
                  {launchModes.map((m) => (
                    <option key={m} value={m}>
                      {launchLabels[m]}
                    </option>
                  ))}
                  {launchValue && !launchModes.includes(launchValue) && <option value={launchValue}>{launchValue} (not recognized, default is used)</option>}
                </select>
                <span className="hint">
                  {hasStartCommand && launchValue !== "command" ? "START_COMMAND is set, so this runs as command. " : ""}
                  {effectiveLaunch === "adapter" ? adapterHint(runtimeId, hasServerBin) : (launchHints[effectiveLaunch] ?? "")}
                </span>
              </div>
              <div className="field">
                <label>Health check</label>
                <select className="select" style={{ width: "100%" }} value={(values.HEALTHCHECK_MODE ?? "").toLowerCase()} onChange={(e) => set("HEALTHCHECK_MODE", e.target.value)}>
                  <option value="">Default (openai-models)</option>
                  {healthModes.map((m) => (
                    <option key={m} value={m}>
                      {healthLabels[m]}
                    </option>
                  ))}
                  {values.HEALTHCHECK_MODE && ![...healthModes, "http200", "off", "none"].includes(values.HEALTHCHECK_MODE.toLowerCase()) && (
                    <option value={values.HEALTHCHECK_MODE.toLowerCase()}>{values.HEALTHCHECK_MODE} (treated as openai-models)</option>
                  )}
                </select>
                <span className="hint">{healthHints[health]}</span>
              </div>
            </div>
            <div className="setting-row">
              <div>
                <div className="title">Capture mode</div>
                <div className="desc">
                  The relay takes over this model's own port, so usage from every app is recorded, even apps you don't reconfigure.
                  {captureBlocked && <span className="hint" style={{ display: "block", marginTop: 4 }}>{captureBlocked}</span>}
                </div>
              </div>
              <Switch on={captureOn} onChange={(on) => set("CAPTURE_MODE", on ? "1" : "")} disabled={!!captureBlocked && !captureOn} label="Capture mode" />
            </div>
            <div className="field">
              <div className="row between">
                <span className="label">{settings.mode === "advanced" ? "All other settings" : "Other settings"}</span>
                <button className="btn sm" onClick={() => setExtra((x) => [...x, { key: "", value: "" }])}>
                  <Plus size={13} /> Add setting
                </button>
              </div>
              {extra.length === 0 && <span className="hint">No other settings. Add runtime flags such as CONTEXT_SIZE, EXTRA_ARGS or START_COMMAND.</span>}
              {extra.map((row, index) => (
                <div className="row" key={index}>
                  <input
                    className="input mono"
                    style={{ maxWidth: 230 }}
                    value={row.key}
                    placeholder="KEY"
                    onChange={(e) => setExtra((x) => x.map((r, i) => (i === index ? { ...r, key: e.target.value.toUpperCase() } : r)))}
                  />
                  <input className="input mono grow" value={row.value} placeholder="value" onChange={(e) => setExtra((x) => x.map((r, i) => (i === index ? { ...r, value: e.target.value } : r)))} />
                  <button className="btn ghost icon" onClick={() => setExtra((x) => x.filter((_, i) => i !== index))} aria-label="Remove setting">
                    <Trash2 size={14} />
                  </button>
                </div>
              ))}
            </div>
          </>
        )}
      </div>
    </Modal>
  );
}
