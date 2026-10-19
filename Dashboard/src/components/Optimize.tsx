import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertTriangle, CheckCircle2, KeyRound, Loader2, Power, RefreshCw, Sparkles, XCircle } from "lucide-react";
import { api, post } from "../lib/api";
import { ago, bytes } from "../lib/format";
import { useApp } from "../lib/state";
import type {
  AppMemory,
  MemorySnapshot,
  OptimizeItem,
  OptimizePlan,
  OptimizePurgeResult,
  OptimizeRunResult,
  OptimizeStepResult,
} from "../lib/types";
import { Confirm, Modal, Notice } from "./ui";

const OPEN_EVENT = "modelmatrix:optimize";

/** Opens the Optimize window from anywhere in the dashboard. */
export function openOptimize() {
  window.dispatchEvent(new Event(OPEN_EVENT));
}

/** Mounted once in the app shell; renders the window while it is open. */
export function OptimizeHost() {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    const show = () => setOpen(true);
    window.addEventListener(OPEN_EVENT, show);
    // Deep link: #/overview/optimize (used by the menu bar app and the CLI).
    if (/\/optimize\b/.test(window.location.hash)) setOpen(true);
    return () => window.removeEventListener(OPEN_EVENT, show);
  }, []);
  const close = () => {
    setOpen(false);
    if (/\/optimize\b/.test(window.location.hash)) history.replaceState(null, "", window.location.hash.replace(/\/optimize\b.*/, ""));
  };
  return open ? <OptimizeModal onClose={close} /> : null;
}

type Preset = "maximum" | "recommended";
type Phase = "idle" | "running" | "purging" | "done";

interface Outcome {
  before?: MemorySnapshot;
  after?: MemorySnapshot;
  freed: number;
  steps: (OptimizeStepResult & { title: string })[];
}

function freedBetween(before?: MemorySnapshot, after?: MemorySnapshot) {
  if (!before || !after) return 0;
  return Math.max(0, before.used_bytes - after.used_bytes, after.free_bytes - before.free_bytes);
}

function OptimizeModal({ onClose }: { onClose: () => void }) {
  const { toast, refreshStatus, refreshOllama, bridge, bridgeCommand } = useApp();
  const [plan, setPlan] = useState<OptimizePlan | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [preset, setPreset] = useState<Preset>("maximum");
  const [selected, setSelected] = useState<Set<string> | null>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const [quitting, setQuitting] = useState<AppMemory | null>(null);

  const load = useCallback(async () => {
    try {
      const next = await api<OptimizePlan>("/api/optimize/plan");
      setPlan(next);
      setError(null);
      // Keep the user's ticks; drop items that are gone; preselect on first load.
      setSelected((current) => {
        const ids = new Set(next.items.map((i) => i.id));
        if (!current) return new Set(next.presets.maximum);
        return new Set([...current].filter((id) => ids.has(id)));
      });
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);
  useEffect(() => {
    if (phase !== "idle") return;
    const timer = window.setInterval(load, 5000);
    return () => window.clearInterval(timer);
  }, [load, phase]);

  const choosePreset = (next: Preset) => {
    setPreset(next);
    if (plan) setSelected(new Set(plan.presets[next]));
  };
  const toggle = (id: string) =>
    setSelected((current) => {
      const next = new Set(current ?? []);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });

  const chosen = useMemo(() => (plan?.items ?? []).filter((i) => selected?.has(i.id)), [plan, selected]);
  const estimate = chosen.reduce((sum, i) => sum + i.bytes, 0);
  const wantsPurge = chosen.some((i) => i.kind === "file_cache");

  const run = async () => {
    if (!plan || !chosen.length) return;
    const titles = Object.fromEntries(plan.items.map((i) => [i.id, i.title]));
    const steps: Outcome["steps"] = [];
    let before: MemorySnapshot | undefined;
    let after: MemorySnapshot | undefined;
    try {
      const ids = chosen.filter((i) => i.kind !== "file_cache").map((i) => i.id);
      if (ids.length) {
        setPhase("running");
        const result = await post<OptimizeRunResult>("/api/optimize/run", { items: ids });
        before = result.before;
        after = result.after;
        result.results.filter((r) => !r.skipped).forEach((r) => steps.push({ ...r, title: titles[r.id] ?? r.id }));
      }
      if (wantsPurge) {
        setPhase("purging");
        const purge = await post<OptimizePurgeResult>("/api/optimize/purge");
        before = before ?? purge.before;
        after = purge.after ?? after;
        steps.push({
          id: "system:file-cache",
          ok: purge.ok,
          skipped: purge.canceled,
          message: purge.message,
          title: titles["system:file-cache"] ?? "Clear file cache",
        });
      }
      const freed = freedBetween(before, after);
      setOutcome({ before, after, freed, steps });
      setPhase("done");
      toast(freed > 0 ? `Optimize freed ${bytes(freed)}` : "Optimize finished", "ok");
    } catch (e) {
      setPhase("idle");
      toast(`Optimize failed: ${(e as Error).message}`, "err");
    } finally {
      refreshStatus();
      refreshOllama();
      load();
    }
  };

  const quitApp = async (app: AppMemory) => {
    try {
      await bridgeCommand("app.quit_app", { path: app.path, name: app.name });
      toast(`Asked ${app.name} to quit`, "ok");
      window.setTimeout(load, 2500);
    } catch (e) {
      toast(`Could not quit ${app.name}: ${(e as Error).message}`, "err");
    }
  };

  const busy = phase === "running" || phase === "purging";
  const footer =
    phase === "done" ? (
      <>
        <button className="btn ghost" onClick={() => { setOutcome(null); setPhase("idle"); }}>
          <RefreshCw size={14} /> Optimize again
        </button>
        <button className="btn primary" onClick={onClose}>
          Done
        </button>
      </>
    ) : (
      <>
        <span className="opt-estimate">
          {chosen.length ? (
            <>
              Up to <b>{bytes(estimate)}</b> from {chosen.length} item{chosen.length === 1 ? "" : "s"}
              {wantsPurge && <span className="muted"> · asks for your password</span>}
            </>
          ) : (
            <span className="muted">Nothing selected</span>
          )}
        </span>
        <button className="btn ghost" onClick={onClose} disabled={busy}>
          Cancel
        </button>
        <button className="btn primary" onClick={run} disabled={busy || !chosen.length}>
          {busy ? <Loader2 size={14} className="spin" /> : <Sparkles size={14} />}
          {phase === "running" ? "Freeing memory…" : phase === "purging" ? "Waiting for password…" : "Optimize now"}
        </button>
      </>
    );

  return (
    <Modal
      title={
        <span className="row" style={{ gap: 8 }}>
          <Sparkles size={18} className="accent-text" /> Optimize memory
        </span>
      }
      onClose={busy ? () => undefined : onClose}
      footer={footer}
    >
      {error && !plan && <Notice kind="bad">{error}</Notice>}
      {!plan && !error && (
        <div className="muted row" style={{ gap: 8 }}>
          <Loader2 size={14} className="spin" /> Measuring memory…
        </div>
      )}
      {plan?.memory && <MemoryBar memory={outcome?.after ?? plan.memory} />}
      {phase === "purging" && (
        <Notice kind="info">
          <KeyRound size={14} style={{ verticalAlign: -2 }} /> macOS is asking for your password to clear the file cache. Cancel the dialog to skip this step.
        </Notice>
      )}
      {outcome ? (
        <OutcomeView outcome={outcome} />
      ) : (
        plan && (
          <>
            <div className="opt-presets">
              <div className="seg" role="tablist" aria-label="Optimize preset">
                {(["maximum", "recommended"] as const).map((name) => (
                  <button key={name} className={preset === name ? "on" : ""} onClick={() => choosePreset(name)} disabled={busy} role="tab" aria-selected={preset === name}>
                    {name === "maximum" ? "Maximum" : "Recommended"} · {bytes(plan.estimates[name]) === "-" ? "0 B" : bytes(plan.estimates[name])}
                  </button>
                ))}
              </div>
              <span className="feed-small">
                {preset === "maximum"
                  ? "Everything not answering a request right now, plus the file cache."
                  : `Unused Ollama models and model servers idle for ${Math.round(plan.thresholds.idle_seconds / 60)}+ minutes. No password needed.`}
              </span>
            </div>
            <div className="opt-list">
              {plan.items.map((item) => (
                <ItemRow key={item.id} item={item} checked={!!selected?.has(item.id)} disabled={busy} onToggle={() => toggle(item.id)} />
              ))}
              {plan.items.length === 1 && (
                <div className="feed-small" style={{ padding: "6px 2px" }}>
                  No models are loaded right now. Clearing the file cache is the only thing left to free.
                </div>
              )}
            </div>
            {plan.apps.length > 0 && (
              <>
                <h3 className="opt-h3">Other apps using memory</h3>
                <div className="opt-list">
                  {plan.apps.map((app) => (
                    <div className="opt-item" key={app.path ?? app.name}>
                      <span className="opt-icon">
                        <Power size={14} />
                      </span>
                      <div className="opt-main">
                        <div className="opt-title">{app.name}</div>
                        <div className="feed-small">
                          {app.processes} process{app.processes === 1 ? "" : "es"}
                          {!app.quittable && " · system or command-line process"}
                        </div>
                      </div>
                      <span className="opt-size mono">{bytes(app.bytes)}</span>
                      {app.quittable && (
                        <button
                          className="btn sm ghost"
                          disabled={busy || !bridge?.app_connected}
                          title={bridge?.app_connected ? `Quit ${app.name}` : "Needs the ModelMatrix menu bar app"}
                          onClick={() => setQuitting(app)}
                        >
                          Quit
                        </button>
                      )}
                    </div>
                  ))}
                </div>
                <div className="feed-small" style={{ marginTop: 6 }}>
                  Optimize never quits apps on its own. Quit asks the app to close normally, so it can offer to save your work.
                </div>
              </>
            )}
          </>
        )
      )}
      {quitting && (
        <Confirm
          title={`Quit ${quitting.name}?`}
          message={<>{quitting.name} is using {bytes(quitting.bytes)}. It closes the way it does when you press ⌘Q, and can still ask to save unsaved work.</>}
          confirmLabel="Quit"
          danger
          onConfirm={() => quitApp(quitting)}
          onClose={() => setQuitting(null)}
        />
      )}
    </Modal>
  );
}

function ItemRow({ item, checked, disabled, onToggle }: { item: OptimizeItem; checked: boolean; disabled: boolean; onToggle: () => void }) {
  const kindLabel = item.kind === "ollama_model" ? "Ollama" : item.kind === "model_server" ? "Model server" : "macOS";
  return (
    <label className={`opt-item ${checked ? "on" : ""}`}>
      <input type="checkbox" className="check" checked={checked} disabled={disabled} onChange={onToggle} />
      <div className="opt-main">
        <div className="opt-title">
          <span className="ellipsis">{item.title}</span>
          <span className="badge">{kindLabel}</span>
          {item.in_use && <span className="badge amber">In use</span>}
          {item.needs_password && <span className="badge">Password</span>}
        </div>
        <div className="feed-small">
          {item.detail}
          {item.last_used_at ? ` Last request ${ago(item.last_used_at)}.` : ""}
        </div>
      </div>
      <span className="opt-size mono">{item.kind === "file_cache" ? `≤ ${bytes(item.bytes)}` : bytes(item.bytes)}</span>
    </label>
  );
}

const SEGMENTS: { key: keyof MemorySnapshot; label: string; className: string }[] = [
  { key: "app_bytes", label: "App", className: "app" },
  { key: "wired_bytes", label: "Wired", className: "wired" },
  { key: "compressed_bytes", label: "Compressed", className: "compressed" },
  { key: "cached_bytes", label: "Cached files", className: "cached" },
  { key: "free_bytes", label: "Free", className: "free" },
];

function MemoryBar({ memory }: { memory: MemorySnapshot }) {
  const total = memory.total_bytes || 1;
  return (
    <div className="opt-memory">
      <div className="opt-memory-head">
        <span>
          <b className="mono">{bytes(memory.used_bytes)}</b> <span className="muted">used of {bytes(memory.total_bytes)}</span>
        </span>
        <span className={`badge ${memory.pressure === "normal" ? "green" : memory.pressure === "warning" ? "amber" : "red"}`}>
          Pressure: {memory.pressure}
        </span>
      </div>
      <div className="opt-bar" aria-hidden>
        {SEGMENTS.map((s) => (
          <i key={s.key} className={s.className} style={{ width: `${((memory[s.key] as number) / total) * 100}%` }} />
        ))}
      </div>
      <div className="legend opt-legend">
        {SEGMENTS.map((s) => (
          <span key={s.key}>
            <i className={`opt-dot ${s.className}`} /> {s.label} <b className="mono">{bytes(memory[s.key] as number)}</b>
          </span>
        ))}
        {memory.swap_used_bytes > 0 && (
          <span>
            Swap <b className="mono">{bytes(memory.swap_used_bytes)}</b>
          </span>
        )}
      </div>
    </div>
  );
}

function OutcomeView({ outcome }: { outcome: Outcome }) {
  const { before, after } = outcome;
  return (
    <div className="opt-outcome">
      <div className="opt-tiles">
        <div className="tile">
          <div className="tile-label">Freed</div>
          <div className="tile-value accent">{outcome.freed > 0 ? bytes(outcome.freed) : "0 B"}</div>
        </div>
        <div className="tile">
          <div className="tile-label">Memory used</div>
          <div className="tile-value sm mono">
            {bytes(before?.used_bytes)} → {bytes(after?.used_bytes)}
          </div>
        </div>
        <div className="tile">
          <div className="tile-label">Free</div>
          <div className="tile-value sm mono">
            {bytes(before?.free_bytes)} → {bytes(after?.free_bytes)}
          </div>
        </div>
      </div>
      <div className="opt-list">
        {outcome.steps.map((step) => (
          <div className="opt-item" key={step.id}>
            <span className={`opt-icon ${step.ok ? "ok" : step.skipped ? "" : "bad"}`}>
              {step.ok ? <CheckCircle2 size={15} /> : step.skipped ? <AlertTriangle size={15} /> : <XCircle size={15} />}
            </span>
            <div className="opt-main">
              <div className="opt-title">{step.title}</div>
              <div className="feed-small">{step.message}</div>
            </div>
            {step.ok && step.bytes ? <span className="opt-size mono">{bytes(step.bytes)}</span> : null}
          </div>
        ))}
      </div>
      {outcome.freed === 0 && (
        <div className="feed-small" style={{ marginTop: 8 }}>
          macOS hands memory back gradually, so the free figure can keep rising for a few seconds.
        </div>
      )}
    </div>
  );
}
