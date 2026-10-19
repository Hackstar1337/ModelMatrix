import { useState } from "react";
import { Check, Download, Pencil, X } from "lucide-react";
import { api, post, query } from "../lib/api";
import { ago, compact, dateTime, num } from "../lib/format";
import { useApp, usePoll } from "../lib/state";
import type { ClientUsage } from "../lib/types";
import { HBars } from "../components/charts";
import { FilterBar } from "../components/overview";
import { Empty, SectionCard } from "../components/ui";

function ClientName({ client, onSaved }: { client: ClientUsage; onSaved: () => void }) {
  const { toast } = useApp();
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState(client.custom_name || client.name || "");
  const save = async (name: string) => {
    try {
      await post("/api/usage/clients/rename", { client_id: client.client_id, name });
      toast(name ? `Renamed to ${name}` : "Name reset", "ok");
      setEditing(false);
      onSaved();
    } catch (e) {
      toast((e as Error).message, "err");
    }
  };
  if (editing) {
    return (
      <span className="row" style={{ gap: 4 }}>
        <input className="input" style={{ padding: "4px 8px", width: 180 }} value={value} autoFocus onChange={(e) => setValue(e.target.value)} onKeyDown={(e) => e.key === "Enter" && save(value.trim())} />
        <button className="btn ghost sm icon" onClick={() => save(value.trim())} aria-label="Save name">
          <Check size={14} />
        </button>
        <button className="btn ghost sm icon" onClick={() => setEditing(false)} aria-label="Cancel">
          <X size={14} />
        </button>
      </span>
    );
  }
  return (
    <span className="row" style={{ gap: 6 }}>
      <span className="accent mono">{client.name || client.detected || client.client_id}</span>
      {client.custom_name && <span className="badge">renamed</span>}
      <button className="btn ghost sm icon" onClick={() => setEditing(true)} aria-label="Rename client" title="Rename">
        <Pencil size={12} />
      </button>
      {client.custom_name && (
        <button className="btn ghost sm" onClick={() => save("")} title="Use the detected name">
          reset
        </button>
      )}
    </span>
  );
}

export function ClientsPage() {
  const { settings } = useApp();
  const params = query({ range: settings.range, host: settings.host, tier: settings.tier });
  const clients = usePoll<{ clients: ClientUsage[] }>((signal) => api(`/api/usage/clients${params}`, { signal }), 5000, [params]);
  const list = clients.data?.clients ?? [];
  const advanced = settings.mode === "advanced";
  return (
    <>
      <div className="page-title">
        <div>
          <h1>Clients</h1>
          <p>Every app that called your models through ModelMatrix. Rename a client to give it a friendly label.</p>
        </div>
        <a className="btn" href={`/api/usage/export.csv${params}`}>
          <Download size={14} /> Export CSV
        </a>
      </div>
      <FilterBar />
      <SectionCard id="clients-table" title="All clients" meta={`${list.length} clients · ${settings.range}`}>
        {list.length ? (
          <div className="table-wrap">
            <table className="tbl">
              <thead>
                <tr>
                  <th>Client</th>
                  <th>Detected as</th>
                  {advanced && <th>Process</th>}
                  <th className="num">Requests</th>
                  <th className="num">Tokens</th>
                  <th className="num">Avg t/s</th>
                  <th>Top model</th>
                  <th>Last seen</th>
                  {advanced && <th>First seen</th>}
                </tr>
              </thead>
              <tbody>
                {list.map((c) => (
                  <tr key={c.client_id}>
                    <td>
                      <ClientName client={c} onSaved={clients.refresh} />
                    </td>
                    <td className="muted">{c.detected || "-"}</td>
                    {advanced && <td className="mono muted">{c.process || "-"}</td>}
                    <td className="num">{compact(c.requests)}</td>
                    <td className="num">{compact(c.tokens)}</td>
                    <td className="num">{c.avg_tps ? num(c.avg_tps) : "-"}</td>
                    <td className="mono">{c.top_model || "-"}</td>
                    <td title={dateTime(c.last_seen)}>{ago(c.last_seen)}</td>
                    {advanced && <td>{dateTime(c.first_seen)}</td>}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <Empty title="No clients in this range">Requests through the relay are grouped by the calling app (User-Agent, X-Client header or process name).</Empty>
        )}
      </SectionCard>
      <SectionCard id="clients-chart" title="Top clients by tokens" meta={settings.range}>
        {list.length ? <HBars rows={list.slice(0, 12).map((c) => ({ name: c.name || c.client_id, value: c.tokens }))} /> : <Empty title="Nothing to chart yet" />}
      </SectionCard>
    </>
  );
}
