import { useEffect, useMemo, useState } from "react";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { api, post } from "../lib/api";
import { useApp } from "../lib/state";
import type { ProfileDocument, ProfileTemplate, RuntimeInfo } from "../lib/types";
import { Modal, Notice, Switch } from "./ui";

const coreFields: { key: string; label: string; hint?: string; placeholder?: string }[] = [
  { key: "DISPLAY_NAME", label: "Display name", placeholder: "Qwen 3 8B" },
  { key: "REQUEST_MODEL", label: "Request model", hint: "Model name clients send", placeholder: "qwen3:8b" },
  { key: "SERVER_MODEL_ID", label: "Server model ID", hint: "ID the server reports (optional)" },
  { key: "PORT", label: "Port", placeholder: "8080" },
  { key: "BASE_URL", label: "Base URL", hint: "OpenAI-compatible base, e.g. http://127.0.0.1:8080/v1" },
  { key: "MODEL_PATH", label: "Model path", hint: "Weights file or folder (managed runtimes)" },
  { key: "LAUNCH_MODE", label: "Launch mode", hint: "managed, external, or command" },
  { key: "HEALTHCHECK_MODE", label: "Health check", hint: "openai-models, http, ollama, ..." },
];
const hidden = new Set(["RUNTIME", "CAPTURE_MODE", "PROFILE_NAME", ...coreFields.map((f) => f.key)]);

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

  function applyTemplate(template: ProfileTemplate) {
    load(template.values);
    if (creating && !name) setName(template.id.replace(/[^a-z0-9-]/gi, "-").toLowerCase());
  }

  const merged = useMemo(() => {
    const result: Record<string, string> = {};
    for (const [k, v] of Object.entries(values)) if (hidden.has(k) && v !== "") result[k] = v;
    for (const { key, value } of extra) if (key.trim()) result[key.trim().toUpperCase()] = value;
    return result;
  }, [values, extra]);

  const set = (key: string, value: string) => setValues((v) => ({ ...v, [key]: value }));

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
            </div>
            <div className="setting-row">
              <div>
                <div className="title">Capture mode</div>
                <div className="desc">The relay takes over this model's own port, so usage from every app is recorded, even apps you don't reconfigure.</div>
              </div>
              <Switch on={values.CAPTURE_MODE === "1"} onChange={(on) => set("CAPTURE_MODE", on ? "1" : "")} label="Capture mode" />
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
