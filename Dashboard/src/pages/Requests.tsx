import { useState } from "react";
import { ChevronLeft, ChevronRight, Download, Search } from "lucide-react";
import { api, query } from "../lib/api";
import { compact, num, pct, seconds } from "../lib/format";
import { useApp, usePoll } from "../lib/state";
import type { RequestRow } from "../lib/types";
import { LatencyChart, VolumeChart } from "../components/charts";
import { FilterBar, RequestsTable } from "../components/overview";
import { SectionCard, Tile } from "../components/ui";

const PAGE = 50;

export function RequestsPage() {
  const { overview, settings, bridge } = useApp();
  const [search, setSearch] = useState("");
  const [offset, setOffset] = useState(0);
  const params = query({ range: settings.range, host: settings.host, tier: settings.tier });
  const log = usePoll<{ requests: RequestRow[] }>(
    (signal) => api(`/api/usage/requests${query({ range: settings.range, host: settings.host, tier: settings.tier, q: search, limit: PAGE, offset })}`, { signal }),
    5000,
    [params, search, offset],
  );
  const s = overview?.summary;
  const rows = log.data?.requests ?? [];
  const requests = s?.requests ?? 0;
  return (
    <>
      <div className="page-title">
        <div>
          <h1>Requests & Latency</h1>
          <p>Throughput, time-to-first-token and the full request log.</p>
        </div>
        <a className="btn" href={`/api/usage/export.csv${params}`}>
          <Download size={14} /> Export CSV
        </a>
      </div>
      <FilterBar />
      <div className="tiles-4" style={{ marginTop: 0, marginBottom: 22 }}>
        <Tile label="Requests" value={compact(requests)} sub={`${s?.errors ?? 0} errors (${requests ? pct(((s?.errors ?? 0) / requests) * 100, 1) : "-"})`} />
        <Tile label="TTFT p50 / p95" value={`${seconds(s?.p50_ttft_ms)} / ${seconds(s?.p95_ttft_ms)}`} sub={`avg ${seconds(s?.avg_ttft_ms)}`} />
        <Tile label="Tokens/s median · peak" value={`${num(s?.p50_tps)} · ${num(s?.peak_tps)}`} sub={`avg ${num(s?.avg_tps, 2)}`} accent />
        <Tile label="Avg duration" value={seconds(s?.avg_duration_ms)} sub={`${compact(s?.total_tokens ?? 0)} tokens total`} />
      </div>
      <div className="grid-2">
        <SectionCard id="throughput" title="Requests + token volume" meta={settings.range}>
          <VolumeChart buckets={overview?.timeseries ?? []} range={settings.range} height={260} />
        </SectionCard>
        <SectionCard id="latency" title="Latency & speed" meta={settings.range}>
          <LatencyChart buckets={overview?.timeseries ?? []} range={settings.range} height={260} />
        </SectionCard>
      </div>
      <SectionCard
        id="request-log"
        title="Request log"
        meta={`${offset + 1}-${offset + rows.length}`}
        actions={
          <div className="row">
            <div className="row card" style={{ padding: "4px 10px", borderRadius: 8 }}>
              <Search size={13} className="muted" />
              <input
                className="input"
                style={{ border: 0, background: "transparent", padding: "2px 4px", width: 200 }}
                placeholder="Search model, client, error"
                value={search}
                onChange={(e) => {
                  setSearch(e.target.value);
                  setOffset(0);
                }}
              />
            </div>
            <button className="btn sm icon" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - PAGE))} aria-label="Previous page">
              <ChevronLeft size={14} />
            </button>
            <button className="btn sm icon" disabled={rows.length < PAGE} onClick={() => setOffset(offset + PAGE)} aria-label="Next page">
              <ChevronRight size={14} />
            </button>
          </div>
        }
      >
        <RequestsTable rows={rows} gateways={bridge?.gateways ?? []} advanced={settings.mode === "advanced"} />
      </SectionCard>
    </>
  );
}
