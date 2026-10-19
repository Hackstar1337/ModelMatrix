import { useMemo } from "react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  ComposedChart,
  Line,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { bucketLabel, compact, num, seconds } from "../lib/format";
import { useApp } from "../lib/state";
import type { Bucket } from "../lib/types";

export function useColors() {
  const { settings } = useApp();
  return useMemo(() => {
    const style = getComputedStyle(document.documentElement);
    const read = (name: string, fallback: string) => style.getPropertyValue(name).trim() || fallback;
    return {
      accent: read("--accent", "#ff6a1a"),
      accent2: read("--accent-2", "#ff8a3d"),
      amber: read("--amber", "#f5a524"),
      text: read("--text", "#ededed"),
      muted: read("--muted", "#8b8b8b"),
      faint: read("--faint", "#5c5c5c"),
      line: read("--line", "#232323"),
      chartIn: read("--chart-in", "#e6e6e6"),
      pieMuted: read("--pie-muted", "#4a4a4a"),
      green: read("--green", "#22c55e"),
      red: read("--red", "#ef4444"),
      blue: read("--blue", "#60a5fa"),
      panel: read("--panel-3", "#1e1e1e"),
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [settings.theme]);
}

const axisFont = { fontFamily: "JetBrains Mono, monospace", fontSize: 12 };

function Tip({ active, payload, label, rows }: any) {
  if (!active || !payload?.length) return null;
  return (
    <div className="chart-tip">
      <div style={{ color: "var(--muted)", marginBottom: 4 }}>{label}</div>
      {rows.map((row: { key: string; label: string; format: (v: number) => string; color: string }) => {
        const item = payload.find((p: any) => p.dataKey === row.key);
        if (!item) return null;
        return (
          <div key={row.key} style={{ color: row.color }}>
            {row.label}: <b>{row.format(item.value)}</b>
          </div>
        );
      })}
    </div>
  );
}

export function VolumeChart({ buckets, range, height = 320 }: { buckets: Bucket[]; range: string; height?: number }) {
  const c = useColors();
  const data = buckets.map((b) => ({
    label: bucketLabel(b.t, range),
    requests: b.requests,
    tin: b.prompt_tokens,
    tout: b.completion_tokens,
  }));
  const interval = Math.max(0, Math.ceil(data.length / 12) - 1);
  return (
    <>
      <div style={{ height }}>
        <ResponsiveContainer width="100%" height="100%">
          <ComposedChart data={data} margin={{ top: 8, right: 4, left: -10, bottom: 0 }} barCategoryGap="22%">
            <CartesianGrid stroke={c.line} vertical={false} />
            <XAxis dataKey="label" tick={{ ...axisFont, fill: c.text }} tickLine={false} axisLine={{ stroke: c.line }} interval={interval} />
            <YAxis yAxisId="req" tick={{ ...axisFont, fill: c.text }} tickLine={false} axisLine={false} allowDecimals={false} width={44} />
            <YAxis yAxisId="tok" orientation="right" tick={{ ...axisFont, fill: c.faint }} tickLine={false} axisLine={false} tickFormatter={(v) => compact(v)} width={48} />
            <Tooltip
              cursor={{ fill: "rgba(255,255,255,0.04)" }}
              content={
                <Tip
                  rows={[
                    { key: "requests", label: "Requests", format: (v: number) => String(v), color: c.accent },
                    { key: "tin", label: "Tokens in", format: compact, color: c.chartIn },
                    { key: "tout", label: "Tokens out", format: compact, color: c.accent2 },
                  ]}
                />
              }
            />
            <Bar yAxisId="req" dataKey="requests" fill={c.accent} radius={[2, 2, 0, 0]} isAnimationActive={false} />
            <Line yAxisId="tok" type="monotone" dataKey="tin" stroke={c.chartIn} strokeWidth={1.4} strokeDasharray="4 3" dot={false} isAnimationActive={false} />
            <Line yAxisId="tok" type="monotone" dataKey="tout" stroke={c.accent2} strokeWidth={1.4} strokeDasharray="4 3" dot={false} isAnimationActive={false} />
          </ComposedChart>
        </ResponsiveContainer>
      </div>
      <div className="legend">
        <span>
          <i style={{ background: c.accent }} /> Requests
        </span>
        <span>
          <i className="line" style={{ background: c.chartIn }} /> Tokens In
        </span>
        <span>
          <i className="line" style={{ background: c.accent2 }} /> Tokens Out
        </span>
      </div>
    </>
  );
}

export function SplitPie({ slices, height = 250 }: { slices: { name: string; value: number; color?: string }[]; height?: number }) {
  const c = useColors();
  const palette = [c.accent, c.pieMuted, c.amber, c.accent2, c.muted, c.blue, c.green, c.faint];
  const total = slices.reduce((sum, s) => sum + s.value, 0);
  const data = total > 0 ? slices.filter((s) => s.value > 0) : [{ name: "No requests", value: 1, color: c.pieMuted }];
  return (
    <>
      <div style={{ height }}>
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie data={data} dataKey="value" nameKey="name" innerRadius={0} outerRadius="88%" stroke={c.panel} strokeWidth={1} isAnimationActive={false} startAngle={90} endAngle={-270}>
              {data.map((slice, index) => (
                <Cell key={slice.name} fill={slice.color ?? palette[index % palette.length]} />
              ))}
            </Pie>
            {total > 0 && (
              <Tooltip
                content={({ active, payload }: any) =>
                  active && payload?.length ? (
                    <div className="chart-tip">
                      {payload[0].name}: <b>{compact(payload[0].value)}</b> ({((payload[0].value / total) * 100).toFixed(1)}%)
                    </div>
                  ) : null
                }
              />
            )}
          </PieChart>
        </ResponsiveContainer>
      </div>
      <div className="legend">
        {slices.map((slice, index) => (
          <span key={slice.name}>
            <i className="round" style={{ background: slice.color ?? palette[index % palette.length] }} /> {slice.name}
          </span>
        ))}
      </div>
    </>
  );
}

export function LatencyChart({ buckets, range, height = 280 }: { buckets: Bucket[]; range: string; height?: number }) {
  const c = useColors();
  const data = buckets.map((b) => ({
    label: bucketLabel(b.t, range),
    ttft: b.avg_ttft_ms ?? null,
    tps: b.avg_tps ?? null,
  }));
  const interval = Math.max(0, Math.ceil(data.length / 12) - 1);
  // With only a few populated buckets a line has nothing to connect, so show points.
  const sparse = data.filter((d) => d.ttft !== null || d.tps !== null).length < 4;
  return (
    <>
      <div style={{ height }}>
        <ResponsiveContainer width="100%" height="100%">
          <ComposedChart data={data} margin={{ top: 8, right: 4, left: 0, bottom: 0 }}>
            <CartesianGrid stroke={c.line} vertical={false} />
            <XAxis dataKey="label" tick={{ ...axisFont, fill: c.text }} tickLine={false} axisLine={{ stroke: c.line }} interval={interval} />
            <YAxis yAxisId="ttft" tick={{ ...axisFont, fill: c.text }} tickLine={false} axisLine={false} tickFormatter={(v) => seconds(v)} width={58} />
            <YAxis yAxisId="tps" orientation="right" tick={{ ...axisFont, fill: c.faint }} tickLine={false} axisLine={false} width={44} />
            <Tooltip
              content={
                <Tip
                  rows={[
                    { key: "ttft", label: "Avg TTFT", format: seconds, color: c.accent },
                    { key: "tps", label: "Avg t/s", format: (v: number) => num(v), color: c.chartIn },
                  ]}
                />
              }
            />
            <Line yAxisId="ttft" type="monotone" dataKey="ttft" stroke={c.accent} strokeWidth={2} dot={sparse ? { r: 3, fill: c.accent, strokeWidth: 0 } : false} connectNulls isAnimationActive={false} />
            <Line yAxisId="tps" type="monotone" dataKey="tps" stroke={c.chartIn} strokeWidth={1.5} strokeDasharray="4 3" dot={sparse ? { r: 3, fill: c.chartIn, strokeWidth: 0 } : false} connectNulls isAnimationActive={false} />
          </ComposedChart>
        </ResponsiveContainer>
      </div>
      <div className="legend">
        <span>
          <i className="line" style={{ background: c.accent }} /> Avg TTFT
        </span>
        <span>
          <i className="line" style={{ background: c.chartIn }} /> Avg tokens/s
        </span>
      </div>
    </>
  );
}

export function HBars({ rows, height }: { rows: { name: string; value: number }[]; height?: number }) {
  const c = useColors();
  return (
    <div style={{ height: height ?? Math.max(160, rows.length * 34 + 20) }}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={rows} layout="vertical" margin={{ top: 0, right: 24, left: 0, bottom: 0 }}>
          <CartesianGrid stroke={c.line} horizontal={false} />
          <XAxis type="number" tick={{ ...axisFont, fill: c.faint }} tickLine={false} axisLine={false} tickFormatter={(v) => compact(v)} />
          <YAxis type="category" dataKey="name" tick={{ ...axisFont, fill: c.text }} tickLine={false} axisLine={false} width={150} />
          <Tooltip cursor={{ fill: "rgba(255,255,255,0.04)" }} content={({ active, payload }: any) => (active && payload?.length ? <div className="chart-tip">{payload[0].payload.name}: <b>{compact(payload[0].value)}</b></div> : null)} />
          <Bar dataKey="value" fill={c.accent} radius={[0, 3, 3, 0]} isAnimationActive={false} barSize={16} />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
