import { useEffect, useState, type ReactNode } from "react";
import { AlertTriangle, CheckCircle2, Copy, Info, Loader2, X, XCircle } from "lucide-react";
import { copyText } from "../lib/format";
import { useApp, type PendingAction } from "../lib/state";
import type { ProfileStatus } from "../lib/types";

/** The 5x5 "M" matrix mark used in the app icon. */
export function MatrixMark({ size = 26 }: { size?: number }) {
  const pattern = ["X...X", "XX.XX", "X.X.X", "X...X", "X...X"];
  const cell = 10;
  return (
    <svg width={size} height={size} viewBox="0 0 54 54" aria-hidden>
      {pattern.flatMap((row, y) =>
        row.split("").map((c, x) => (
          <rect
            key={`${x}-${y}`}
            x={2 + x * cell + x * 0.5}
            y={2 + y * cell + y * 0.5}
            width={cell - 2}
            height={cell - 2}
            rx={1.8}
            fill={c === "X" ? "var(--accent)" : "var(--panel-3)"}
          />
        )),
      )}
    </svg>
  );
}

export function Modal({
  title,
  onClose,
  children,
  footer,
  small,
}: {
  title: ReactNode;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
  small?: boolean;
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal ${small ? "sm" : ""}`} role="dialog" aria-modal="true">
        <div className="modal-head">
          <h2>{title}</h2>
          <button className="icon-btn" onClick={onClose} aria-label="Close">
            <X size={18} />
          </button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-foot">{footer}</div>}
      </div>
    </div>
  );
}

export function Confirm({
  title,
  message,
  confirmLabel = "Confirm",
  danger,
  onConfirm,
  onClose,
}: {
  title: string;
  message: ReactNode;
  confirmLabel?: string;
  danger?: boolean;
  onConfirm: () => Promise<void> | void;
  onClose: () => void;
}) {
  const [busy, setBusy] = useState(false);
  return (
    <Modal
      small
      title={title}
      onClose={onClose}
      footer={
        <>
          <button className="btn ghost" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button
            className={`btn ${danger ? "danger" : "primary"}`}
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              try {
                await onConfirm();
                onClose();
              } finally {
                setBusy(false);
              }
            }}
          >
            {busy && <Loader2 size={14} className="spin" />}
            {confirmLabel}
          </button>
        </>
      }
    >
      <div className="muted" style={{ fontSize: 14 }}>
        {message}
      </div>
    </Modal>
  );
}

export function Toasts() {
  const { toasts, dismiss } = useApp();
  return (
    <div className="toasts" aria-live="polite">
      {toasts.map((t) => (
        <div key={t.id} className={`toast ${t.kind}`} onClick={() => dismiss(t.id)}>
          {t.kind === "ok" ? (
            <CheckCircle2 size={16} className="green" />
          ) : t.kind === "err" ? (
            <XCircle size={16} className="red" />
          ) : (
            <Info size={16} className="accent" />
          )}
          <span>{t.text}</span>
        </div>
      ))}
    </div>
  );
}

export function Switch({ on, onChange, disabled, label }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean; label?: string }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      className={`switch ${on ? "on" : ""}`}
      disabled={disabled}
      onClick={() => onChange(!on)}
    />
  );
}

export function profileState(status: ProfileStatus, pending?: PendingAction) {
  if (pending) return { cls: "busy", label: pending };
  if (status.missing_artifacts && status.missing_artifacts.length) return { cls: "error", label: "MISSING FILES" };
  if (status.ready) return { cls: "ready", label: "READY" };
  if (status.running) return { cls: "running", label: "LOADING" };
  return { cls: "stopped", label: "STOPPED" };
}

export function StatusPill({ status, pending }: { status: ProfileStatus; pending?: PendingAction }) {
  const state = profileState(status, pending);
  return (
    <span className={`status-pill ${state.cls}`}>
      {state.cls === "busy" ? <Loader2 size={11} className="spin" /> : <span className={`dot ${state.cls === "ready" ? "on" : state.cls === "running" ? "warn" : state.cls === "error" ? "off" : ""}`} />}
      {state.label}
    </span>
  );
}

export function CopyButton({ text, label }: { text: string; label?: string }) {
  const { toast } = useApp();
  return (
    <button
      className="btn ghost sm"
      title={`Copy ${text}`}
      onClick={async () => {
        const ok = await copyText(text);
        toast(ok ? `Copied ${label ?? text}` : "Copy failed", ok ? "ok" : "err");
      }}
    >
      <Copy size={13} />
      {label && <span>{label}</span>}
    </button>
  );
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <b>{title}</b>
      {children}
    </div>
  );
}

export function Notice({ kind = "info", children }: { kind?: "info" | "warn" | "bad"; children: ReactNode }) {
  return (
    <div className={`notice ${kind === "info" ? "" : kind}`}>
      {kind === "info" ? <Info size={16} /> : <AlertTriangle size={16} />}
      <div>{children}</div>
    </div>
  );
}

export function Tile({ label, value, sub, accent, trendValue }: { label: string; value: ReactNode; sub?: ReactNode; accent?: boolean; trendValue?: number | null }) {
  return (
    <div className="tile">
      <div className="tile-label">{label}</div>
      <div className={`tile-value ${accent ? "accent" : ""}`}>
        {value}
        {trendValue !== undefined && trendValue !== null && (
          <span className={`tile-trend ${trendValue >= 0 ? "green" : "red"}`}>
            {trendValue >= 0 ? "▲" : "▼"} {Math.abs(trendValue).toFixed(0)}%
          </span>
        )}
      </div>
      {sub !== undefined && <div className="tile-sub">{sub}</div>}
    </div>
  );
}

export function SectionCard({
  id,
  title,
  meta,
  actions,
  children,
  className = "",
}: {
  id?: string;
  title: ReactNode;
  meta?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section id={id} className={`card card-pad section ${className}`}>
      <div className="card-head">
        <div className="card-title">{title}</div>
        <div className="row">
          {meta && <span className="card-meta">{meta}</span>}
          {actions}
        </div>
      </div>
      {children}
    </section>
  );
}

export function Meter({ label, percent, value }: { label: string; percent: number | null | undefined; value: ReactNode }) {
  const width = Math.max(0, Math.min(100, percent ?? 0));
  return (
    <div className="meter">
      <span className="meter-label">{label}</span>
      <span className="meter-track">
        <i style={{ width: `${width}%` }} />
      </span>
      <span className="meter-val">{value}</span>
    </div>
  );
}
