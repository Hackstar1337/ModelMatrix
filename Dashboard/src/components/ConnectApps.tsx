import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Clipboard, Eye, EyeOff, Link2, Loader2, Plug, RefreshCw, ShieldCheck, Unplug, Undo2 } from "lucide-react";
import { copyText } from "../lib/format";
import { useApp } from "../lib/state";
import { connectApply, connectDetails, connectDisconnect, connectList, connectPlan, connectProfiles, connectSecret, connectTargets, connectUndo, connectVerify, type ConnectConnection, type ConnectDetails, type ConnectPlan, type ConnectProfile, type ConnectTarget, type ConnectTargetId } from "../lib/connect";
import { Confirm, CopyButton, Empty, Modal, Notice, SectionCard } from "./ui";

type DialogStage = "choose" | "preview";
type ConfirmAction = "verify" | "disconnect" | "undo" | null;

function readinessLabel(value?: string) {
  if (!value) return "unknown";
  return value.replace(/[_-]+/g, " ");
}

function findProfile(profiles: ConnectProfile[], key?: string, host?: string) {
  if (!key) return profiles[0];
  return profiles.find((p) => p.key === key) || profiles.find((p) => p.profile === key && (!host || p.host === host || p.key.includes(`${host}:`)));
}

function statusClass(value: boolean | undefined, kind: "good" | "warn" = "good") {
  if (value) return "badge green";
  return kind === "warn" ? "badge amber" : "badge";
}

function ConnectionStates({ connection }: { connection: ConnectConnection }) {
  return (
    <div className="connect-states" aria-label="Connection states">
      <span className={statusClass(connection.configured)}><span className={`dot ${connection.configured ? "on" : ""}`} /> {connection.configured ? "Configured" : "Not configured"}</span>
      <span className={statusClass(connection.api_tested)}><span className={`dot ${connection.api_tested ? "on" : ""}`} /> {connection.api_tested ? "API tested" : "API not tested"}</span>
      <span className={statusClass(connection.client_verified, "warn")}><span className={`dot ${connection.client_verified ? "on" : "warn"}`} /> {connection.client_verified ? "Client verified" : "Client not verified"}</span>
      <span className={statusClass(!connection.reload_required, "warn")}><span className={`dot ${connection.reload_required ? "warn" : "on"}`} /> {connection.reload_required ? "Reload required" : "Reload not required"}</span>
      <span className={statusClass(connection.readiness === "ready" || connection.readiness === "running", "warn")}>Readiness: {readinessLabel(connection.readiness)}</span>
    </div>
  );
}

function SecretActions({ connection }: { connection: ConnectConnection }) {
  const { toast } = useApp();
  const [secret, setSecret] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [visible, setVisible] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const reveal = async () => {
    setBusy(true);
    try {
      const result = await connectSecret(connection.id);
      setSecret(result.key);
      setVisible(true);
      toast("Private key revealed only in this dialog; it is not saved by the dashboard", "info");
    } catch (e) {
      toast(`Couldn't retrieve private key: ${(e as Error).message}`, "err");
    } finally {
      setBusy(false);
    }
  };
  const copy = async () => {
    if (!secret) return;
    const ok = await copyText(secret);
    toast(ok ? "Private key copied. Treat it like a password." : "Copy failed", ok ? "ok" : "err");
  };
  return (
    <>
      <div className="connect-secret">
        <div className="row" style={{ justifyContent: "space-between", gap: 10 }}>
        <div>
          <b>Private key</b>
          <div className="muted hf-small">Never included in normal connection responses or URLs.</div>
        </div>
          {!secret ? (
          <button className="btn sm" disabled={busy} onClick={() => setConfirming(true)}>
            {busy ? <Loader2 size={13} className="spin" /> : <Eye size={13} />} Reveal key
          </button>
          ) : (
          <div className="row">
            <button className="btn sm" onClick={() => setVisible((v) => !v)}>{visible ? <EyeOff size={13} /> : <Eye size={13} />} {visible ? "Hide" : "Show"}</button>
            <button className="btn sm" onClick={copy}><Clipboard size={13} /> Copy key</button>
          </div>
        )}
        </div>
        {secret && visible && <div className="code connect-secret-value"><span className="mono">{secret}</span></div>}
        {secret && <Notice kind="warn">This secret is held in memory by this dialog only. Clear it by closing the dialog and do not paste it into a ticket or chat.</Notice>}
      </div>
      {confirming && <Confirm title="Reveal the private key?" message="The key will be fetched explicitly and shown only in memory in this dialog. Never paste it into settings, URLs, logs, or support tickets." confirmLabel="Reveal private key" onClose={() => setConfirming(false)} onConfirm={async () => { setConfirming(false); await reveal(); }} />}
    </>
  );
}

function DetailsPanel({ details }: { details: ConnectDetails }) {
  return (
    <div className="connect-details stack">
      <div className="row wrap" style={{ justifyContent: "space-between" }}>
        <div><b>{details.display_name}</b><div className="muted mono hf-small">{details.model_id}</div></div>
        <span className={`badge ${details.readiness === "ready" ? "green" : "amber"}`}>Readiness: {readinessLabel(details.readiness)}</span>
      </div>
      <dl className="kv">
        <dt>Provider</dt><dd>{details.provider}</dd>
        <dt>Base URL</dt><dd>{details.base_url}<CopyButton text={details.base_url} label="copy" /></dd>
        <dt>Server root</dt><dd>{details.server_root}<CopyButton text={details.server_root} label="copy" /></dd>
        <dt>Model list</dt><dd>{details.model_list_url}<CopyButton text={details.model_list_url} label="copy" /></dd>
        <dt>Chat endpoint</dt><dd>{details.chat_url}<CopyButton text={details.chat_url} label="copy" /></dd>
        <dt>Authentication</dt><dd>{details.api_key_requirement.replace(/_/g, " ")}{details.credential_kind ? ` · ${details.credential_kind}` : ""}</dd>
        <dt>Capabilities</dt><dd>Chat {details.capabilities.chat ? "yes" : "no"} · Tools {details.capabilities.tools} · Images {details.capabilities.images} · Embeddings {details.capabilities.embeddings}</dd>
      </dl>
      <div className="connect-copy-grid">
        <div><span className="connect-label">Summary</span><div className="code"><span>{details.summary}</span><CopyButton text={details.summary} label="copy" /></div></div>
        <div><span className="connect-label">Request example</span><div className="code"><span className="mono">{details.request_example}</span><CopyButton text={details.request_example} label="copy" /></div></div>
      </div>
      {!!details.notes.length && <Notice>{details.notes.join(" ")}</Notice>}
    </div>
  );
}

function ConnectDialog({ initialProfile, initialHost, initialConnection, onClose, onChanged }: { initialProfile?: string; initialHost?: string; initialConnection?: ConnectConnection; onClose: () => void; onChanged: () => void }) {
  const { toast } = useApp();
  const [profiles, setProfiles] = useState<ConnectProfile[]>([]);
  const [targets, setTargets] = useState<ConnectTarget[]>([]);
  const [profileKey, setProfileKey] = useState(initialConnection?.profile_key || initialProfile || "");
  const [target, setTarget] = useState<ConnectTargetId>(initialConnection?.target || "kilo");
  const [makeDefault, setMakeDefault] = useState(false);
  const [details, setDetails] = useState<ConnectDetails>();
  const [plan, setPlan] = useState<ConnectPlan>();
  const [connection, setConnection] = useState<ConnectConnection | undefined>(initialConnection);
  const [stage, setStage] = useState<DialogStage>("choose");
  const [approved, setApproved] = useState(false);
  const [confirm, setConfirm] = useState<ConfirmAction>(null);
  const [busy, setBusy] = useState<string>();
  const [error, setError] = useState<string>();
  const detailsRequest = useRef(0);

  const selectedProfile = useMemo(() => findProfile(profiles, profileKey, initialHost), [profiles, profileKey, initialHost]);
  const autoTargets = targets.filter((t) => t.id === "kilo" || t.id === "opencode");
  const selectedTarget = autoTargets.find((t) => t.id === target);
  const loadDetails = useCallback(async (key: string, id?: string) => {
    if (!key) return;
    const request = ++detailsRequest.current;
    setDetails(undefined);
    try {
      const value = await connectDetails(key, id);
      if (request === detailsRequest.current) setDetails(value);
    } catch (e) {
      if (request === detailsRequest.current) setError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    Promise.all([connectProfiles(), connectTargets()]).then(([p, t]) => {
      if (cancelled) return;
      setProfiles(p.profiles);
      setTargets(t.targets);
      const match = findProfile(p.profiles, initialConnection?.profile_key || initialProfile, initialHost);
      if (match) {
        setProfileKey(match.key);
        void loadDetails(match.key, initialConnection?.id);
      }
    }).catch((e) => !cancelled && setError((e as Error).message));
    return () => { cancelled = true; };
  }, [initialConnection?.id, initialConnection?.profile_key, initialProfile, initialHost, loadDetails]);

  useEffect(() => {
    if (profileKey) {
      const connectionId = connection?.profile_key === profileKey && connection.configured ? connection.id : undefined;
      void loadDetails(profileKey, connectionId);
    }
  }, [profileKey, connection?.id, connection?.profile_key, connection?.configured, loadDetails]);

  const run = async (name: string, action: () => Promise<void>) => {
    setBusy(name);
    setError(undefined);
    try { await action(); } catch (e) { setError((e as Error).message); } finally { setBusy(undefined); }
  };

  const makePlan = () => run("plan", async () => {
    if (!profileKey) throw new Error("Select a model profile first");
    const result = await connectPlan(profileKey, target, makeDefault);
    setPlan(result.plan);
    setConnection(undefined);
    setApproved(false);
    setStage("preview");
  });

  const apply = () => run("apply", async () => {
    if (!plan || !approved) return;
    const result = await connectApply(plan.id);
    setConnection(result.connection);
    setPlan(undefined);
    setApproved(false);
    setStage("choose");
    toast(result.existing ? "Connection updated using its existing identity" : "App connection configured", "ok");
    onChanged();
  });

  const verify = () => {
    if (!connection) return;
    setConfirm(null);
    void run("verify", async () => {
      const result = await connectVerify(connection.id);
      setConnection(result.connection);
      toast(result.message || "API test completed", "ok");
      onChanged();
    });
  };
  const disconnect = () => {
    if (!connection) return;
    setConfirm(null);
    void run("disconnect", async () => {
      const result = await connectDisconnect(connection.id);
      setConnection(result.connection);
      toast(result.message || "Connection disconnected", "ok");
      onChanged();
    });
  };
  const undo = () => {
    if (!connection) return;
    setConfirm(null);
    void run("undo", async () => {
      const result = await connectUndo(connection.id);
      setConnection(result.connection);
      toast(result.message || "Connection undo completed", "ok");
      onChanged();
    });
  };

  const title = connection && !plan ? "Manage app connection" : stage === "preview" ? "Review connection changes" : "Connect to an app";
  return (
    <>
      <Modal title={title} onClose={onClose} footer={
        <>
          <button className="btn ghost" onClick={onClose} disabled={!!busy}>Close</button>
          {stage === "choose" && <button className="btn primary" onClick={makePlan} disabled={!!busy || !profileKey || (target !== "manual" && !selectedTarget?.qualified)}>{busy === "plan" && <Loader2 size={14} className="spin" />} Preview changes</button>}
          {stage === "preview" && <button className="btn primary" onClick={apply} disabled={!!busy || !approved}>{busy === "apply" && <Loader2 size={14} className="spin" />} Approve & configure</button>}
        </>
      }>
        <div className="stack">
          {error && <Notice kind="bad">{error}</Notice>}
          {stage === "choose" && (
            <>
              <div className="connect-picker-head">
                <div><b>Choose a ModelMatrix profile</b><div className="muted">Local and remote runnable profiles are listed by the key returned from the controller.</div></div>
                <span className="badge">{profiles.length} available</span>
              </div>
              {!profiles.length ? <Empty title="No runnable profiles yet">Start or create a profile in Models & Servers, then return here. You can still open this action before any model is downloaded.</Empty> : (
                <div className="field">
                  <label htmlFor="connect-profile">Profile</label>
                  <select id="connect-profile" className="select" style={{ width: "100%" }} value={selectedProfile?.key || profileKey} onChange={(e) => { setProfileKey(e.target.value); setConnection(undefined); }}>
                    {profiles.map((p) => <option value={p.key} key={p.key}>{p.display_name} · {p.model_id} · {p.host ? `${p.host} · ` : "local · "}{p.runtime}</option>)}
                  </select>
                  {selectedProfile && <span className="hint mono">{selectedProfile.key} · context {selectedProfile.context ?? "unknown"} · {readinessLabel(selectedProfile.readiness)}</span>}
                </div>
              )}
              <div className="connect-target-block">
                <div className="connect-picker-head"><div><b>Automatic app setup</b><div className="muted">Only qualified installed Kilo and OpenCode builds can be selected automatically.</div></div></div>
                <div className="connect-targets">
                  {autoTargets.map((item) => {
                    const enabled = item.installed && item.qualified;
                    return <button type="button" key={item.id} className={`connect-target ${target === item.id ? "selected" : ""}`} disabled={!enabled} onClick={() => setTarget(item.id)}><span className="connect-target-title">{item.name}</span><span className={`badge ${enabled ? "green" : "amber"}`}>{item.version || (item.installed ? "installed" : "not installed")}</span><span className="connect-target-note">{enabled ? (item.reload_note || "Qualified automatic adapter") : (item.reason || "Not qualified")}</span></button>;
                  })}
                  <button type="button" className={`connect-target ${target === "manual" ? "selected" : ""}`} onClick={() => setTarget("manual")}><span className="connect-target-title">Other app</span><span className="badge blue">manual</span><span className="connect-target-note">Use the details below for any OpenAI-compatible client.</span></button>
                </div>
              </div>
              {details && <DetailsPanel details={details} />}
              {target === "manual" && <Notice kind="warn">Other app is a manual protected connection. Copy only the non-secret endpoint, model ID, and request example; client verification is not claimed by an API test.</Notice>}
              <label className="row connect-default"><input className="check" type="checkbox" checked={makeDefault} onChange={(e) => setMakeDefault(e.target.checked)} /> Make this model the selected app default <span className="muted">(off by default)</span></label>
              {connection && <ConnectionManager connection={connection} onReconfigure={() => { setConnection(undefined); setPlan(undefined); setStage("choose"); }} onConfirm={(kind) => setConfirm(kind)} />}
            </>
          )}
          {stage === "preview" && plan && (
            <>
              <Notice>Read-only preview. No config, route, credential, or client setting is written until you approve this exact, expiring plan.</Notice>
              <div className="connect-plan-title"><b>{plan.title}</b><span className="badge orange">{plan.target}{plan.target_version ? ` ${plan.target_version}` : ""}</span></div>
              <dl className="kv"><dt>Config path</dt><dd>{plan.config_path || "manual client"}</dd><dt>Expires</dt><dd>{plan.expires_at ? new Date(plan.expires_at).toLocaleString() : "controller-defined"}</dd><dt>Provider</dt><dd>{plan.provider_id}</dd><dt>Model key</dt><dd>{plan.model_key}</dd><dt>Wire model ID</dt><dd>{plan.model_id}</dd><dt>Base URL</dt><dd>{plan.base_url}</dd><dt>Credential storage</dt><dd>{plan.credential_storage}</dd></dl>
              <div><span className="connect-label">Changes</span><ul className="connect-list">{plan.changes.map((item) => <li key={item}>{item}</li>)}</ul></div>
              {!!plan.notes.length && <Notice kind="warn">{plan.notes.join(" ")}</Notice>}
              <div className="code"><span><b>Recovery:</b> {plan.recovery}</span></div>
              <label className="row connect-approval"><input className="check" type="checkbox" checked={approved} onChange={(e) => setApproved(e.target.checked)} /> I reviewed this exact plan and approve the protected change.</label>
            </>
          )}
          {connection && stage === "choose" && <SecretActions connection={connection} />}
        </div>
      </Modal>
      {confirm === "verify" && <Confirm title="Run the scoped API test?" message="This sends the controller's authenticated model-list and short chat test. It does not verify that Kilo or OpenCode has reloaded the configuration." confirmLabel="Run API test" onClose={() => setConfirm(null)} onConfirm={verify} />}
      {confirm === "disconnect" && <Confirm title="Disconnect this app?" message="The owned configuration block is removed only when it is still safe to do so. The connection route and key are revoked; the model and app are not deleted." confirmLabel="Approve disconnect" danger onClose={() => setConfirm(null)} onConfirm={disconnect} />}
      {confirm === "undo" && <Confirm title="Undo this connection?" message="Undo is ownership-aware and refuses to overwrite unrelated edits. A revoked credential is never restored." confirmLabel="Approve undo" danger onClose={() => setConfirm(null)} onConfirm={undo} />}
    </>
  );
}

function ConnectionManager({ connection, onReconfigure, onConfirm }: { connection: ConnectConnection; onReconfigure: () => void; onConfirm: (kind: Exclude<ConfirmAction, null>) => void }) {
  return (
    <div className="connect-manager stack">
      <div className="row wrap" style={{ justifyContent: "space-between" }}><div><b>Existing connection</b><div className="muted mono hf-small">{connection.id} · {connection.target}</div></div><span className="badge orange">{readinessLabel(connection.state)}</span></div>
      <ConnectionStates connection={connection} />
      {connection.message && <div className="muted">{connection.message}</div>}
      <div className="btn-row"><button className="btn sm" onClick={() => onConfirm("verify")}><ShieldCheck size={13} /> Test API</button><button className="btn sm" onClick={onReconfigure}><RefreshCw size={13} /> Reconfigure</button><button className="btn sm" onClick={() => onConfirm("undo")}><Undo2 size={13} /> Undo</button><button className="btn sm danger" onClick={() => onConfirm("disconnect")}><Unplug size={13} /> Disconnect</button></div>
      {connection.reload_required && <Notice kind="warn">The target may need a client reload. ModelMatrix never restarts your editor or TUI automatically.</Notice>}
    </div>
  );
}

function ConnectionRow({ connection, onManage }: { connection: ConnectConnection; onManage: () => void }) {
  return <div className="connect-row"><div className="connect-row-main"><div className="row wrap"><b>{connection.display_name}</b><span className="badge orange">{connection.target}</span></div><div className="muted mono hf-small">{connection.profile_key} · {connection.model_id}</div><ConnectionStates connection={connection} /></div><button className="btn sm" onClick={onManage}><Link2 size={13} /> Manage</button></div>;
}

export function ConnectAppsLauncher({ profileKey, host, label = "Connect", className = "btn sm" }: { profileKey?: string; host?: string; label?: string; className?: string }) {
  const [open, setOpen] = useState(false);
  return <><button className={className} onClick={() => setOpen(true)}><Plug size={13} /> {label}</button>{open && <ConnectDialog initialProfile={profileKey} initialHost={host} onClose={() => setOpen(false)} onChanged={() => undefined} />}</>;
}

export function ConnectAppsSection() {
  const [connections, setConnections] = useState<ConnectConnection[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>();
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<ConnectConnection>();
  const [refresh, setRefresh] = useState(0);
  const load = useCallback(async () => {
    try { const result = await connectList(); setConnections(result.connections); setError(undefined); } catch (e) { setError((e as Error).message); } finally { setLoading(false); }
  }, []);
  useEffect(() => { void load(); const timer = window.setInterval(load, 8000); return () => window.clearInterval(timer); }, [load, refresh]);
  return <>
    <SectionCard id="connect-app" title={<><Plug size={16} className="accent" /> Connect to an app</>} meta={`${connections.length} connection${connections.length === 1 ? "" : "s"}`} actions={<button className="btn sm primary" onClick={() => { setSelected(undefined); setOpen(true); }}><Plug size={13} /> New connection</button>}>
      <div className="connect-section-intro"><div><b>Use a qualified Kilo/OpenCode adapter or copy details to another app.</b><div className="muted">This entry remains available even when no models have been downloaded. Read-only details do not start models or write settings.</div></div><button className="btn sm ghost" onClick={() => void load()} disabled={loading}><RefreshCw size={13} className={loading ? "spin" : ""} /> Refresh</button></div>
      {error && <Notice kind="bad">{error}</Notice>}
      {!loading && !connections.length && <Empty title="No app connections yet">Choose a local or remote profile to preview a qualified adapter. Other app details are available without automatic setup.</Empty>}
      <div className="connect-list-rows">{connections.map((c) => <ConnectionRow key={c.id} connection={c} onManage={() => { setSelected(c); setOpen(true); }} />)}</div>
    </SectionCard>
    {open && <ConnectDialog initialProfile={selected?.profile_key} initialConnection={selected} onClose={() => { setOpen(false); setSelected(undefined); }} onChanged={() => setRefresh((v) => v + 1)} />}
  </>;
}
