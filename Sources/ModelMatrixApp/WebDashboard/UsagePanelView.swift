import SwiftUI

/// Menu bar twin of the web dashboard's Overview: KPIs, live feed, model split,
/// clients, relay, capture mode and Ollama, with the same actions.
struct UsagePanelView: View {
    @Bindable var monitor: UsageMonitor
    let store: MatrixStore
    let theme: DashboardTheme
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            if let message = monitor.errorMessage {
                UsageNotice(text: message, color: .red, theme: theme)
            } else if let notice = monitor.noticeMessage {
                UsageNotice(text: notice, color: accent, theme: theme)
            }
            kpis
            UsageLiveFeed(monitor: monitor, theme: theme, accent: accent)
            UsageModelSplit(monitor: monitor, theme: theme, accent: accent)
            UsageClientsSection(monitor: monitor, theme: theme, accent: accent)
            UsageRelaySection(monitor: monitor, theme: theme, accent: accent)
            UsageCaptureSection(monitor: monitor, theme: theme, accent: accent)
            UsageOllamaSection(monitor: monitor, theme: theme, accent: accent)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
        .onAppear {
            monitor.start { WebDashboardClient.local(store) }
        }
        .onDisappear { monitor.stop() }
    }

    var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SettingsLinkButton(title: "Open Web Dashboard", emphasized: true, theme: theme, accent: accent) {
                    WebDashboard.open(store)
                }
                SettingsLinkButton(title: "Export CSV", theme: theme, accent: accent) {
                    monitor.exportCSV()
                }
                Spacer(minLength: 0)
                if monitor.isWorking { ProgressView().controlSize(.small) }
            }
            // Stacked: side by side, the two controls wrap their labels in the narrow panel.
            VStack(alignment: .leading, spacing: 6) {
                SettingsSegmentedControl(
                    options: UsageMonitor.ranges, label: { $0 }, selection: $monitor.range, theme: theme)
                SettingsSegmentedControl(
                    options: UsageMonitor.tiers,
                    label: { $0 == "all" ? "All" : $0.capitalized },
                    selection: $monitor.tier,
                    theme: theme)
            }
        }
    }

    var kpis: some View {
        let summary = monitor.summary
        let totals = monitor.totals
        let requests = summary?.double("requests") ?? 0
        let local = summary?.double("local_requests") ?? 0
        let localShare = requests > 0 ? local / requests * 100 : 0
        let cells: [(String, String, String?)] = [
            ("REQUESTS", UsageFormat.compact(summary?.double("requests")), "all time \(UsageFormat.compact(totals?.double("requests")))"),
            ("TOKENS", UsageFormat.compact(summary?.double("total_tokens")), "out \(UsageFormat.compact(summary?.double("completion_tokens")))"),
            ("AVG T/S", UsageFormat.number(summary?.double("avg_tps")), "peak \(UsageFormat.number(summary?.double("peak_tps")))"),
            ("TTFT P50", UsageFormat.seconds(summary?.double("p50_ttft_ms")), "p95 \(UsageFormat.seconds(summary?.double("p95_ttft_ms")))"),
            ("CLIENTS", UsageFormat.compact(summary?.double("clients")), "active \(UsageFormat.compact(totals?.double("active_clients")))"),
            ("REQ/MIN", UsageFormat.number(totals?.double("requests_per_minute")), nil),
            ("LOCAL/CLOUD", requests > 0 ? String(format: "%.0f/%.0f%%", localShare, 100 - localShare) : "-", nil),
            ("INF. TIME", UsageFormat.duration(totals?.double("inference_ms")), "\(UsageFormat.compact(summary?.double("errors"))) errors"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(cells, id: \.0) { cell in
                UsageTile(label: cell.0, value: cell.1, sub: cell.2, highlight: cell.0 == "AVG T/S", theme: theme, accent: accent)
            }
        }
    }
}

struct UsageTile: View {
    let label: String
    let value: String
    let sub: String?
    var highlight = false
    let theme: DashboardTheme
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(theme.faint)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(highlight ? accent : theme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sub {
                Text(sub)
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.sub)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.cellBg))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 0.5))
    }
}

struct UsageNotice: View {
    let text: String
    let color: Color
    let theme: DashboardTheme

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.label)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.4), lineWidth: 0.5))
    }
}

/// Section header + card body shared by the Usage and Profiles panels.
struct UsageCard<Content: View>: View {
    let title: String
    var meta: String?
    let theme: DashboardTheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                DashboardSectionLabel(text: title, theme: theme)
                Spacer()
                if let meta {
                    Text(meta)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.cellBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 0.5))
        }
    }
}

struct UsageLiveFeed: View {
    let monitor: UsageMonitor
    let theme: DashboardTheme
    let accent: Color

    var body: some View {
        UsageCard(title: "LIVE FEED", meta: "\(monitor.inFlight.count) in flight", theme: theme) {
            if monitor.inFlight.isEmpty && monitor.recent.isEmpty {
                Text("No requests yet. Point an app at the relay URL below.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.sub)
                    .padding(12)
            }
            ForEach(monitor.inFlight) { row in
                feedRow(row, live: true)
            }
            ForEach(Array(monitor.recent.prefix(8))) { row in
                feedRow(row, live: false)
            }
        }
    }

    func feedRow(_ row: JSONRow, live: Bool) -> some View {
        let client = row.string("client_name") ?? row.string("client_label") ?? row.string("client_id") ?? "unknown"
        let failed = (row.int("status") ?? 200) >= 400 || row.string("error") != nil
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(live ? accent : (failed ? Color.red : theme.line))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.string("model") ?? "-")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.label)
                        .lineLimit(1)
                    if row.string("tier") == "cloud" {
                        Text("CLOUD").font(.system(size: 8.5, weight: .bold)).foregroundStyle(accent)
                    }
                    Spacer(minLength: 4)
                    Text(live ? "streaming" : "\(UsageFormat.number(row.double("tokens_per_second"))) t/s")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(live ? accent : theme.label)
                }
                HStack(spacing: 6) {
                    Text(client).foregroundStyle(accent).lineLimit(1)
                    Spacer(minLength: 4)
                    if !live {
                        Text("TTFT \(UsageFormat.seconds(row.double("ttft_ms")))")
                        Text("\(UsageFormat.compact(row.double("completion_tokens"))) tok")
                    }
                    Text(UsageFormat.clock(row.double("started_at")))
                }
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(theme.sub)
                if failed, let error = row.string("error") {
                    Text(error).font(.system(size: 9.5)).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(live ? accent.opacity(0.07) : Color.clear)
    }
}
