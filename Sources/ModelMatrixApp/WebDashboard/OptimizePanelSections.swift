import SwiftUI

/// Activity Monitor style memory bar: App, Wired, Compressed, Cached files, Free.
struct OptimizeMemoryCard: View {
    let memory: JSONRow
    let theme: DashboardTheme
    let accent: Color

    var segments: [(label: String, key: String, color: Color)] {
        [
            ("App", "app_bytes", accent),
            ("Wired", "wired_bytes", Color(red: 0.65, green: 0.55, blue: 0.98)),
            ("Compressed", "compressed_bytes", Color(red: 0.38, green: 0.65, blue: 0.98)),
            ("Cached files", "cached_bytes", theme.faint.opacity(0.7)),
            ("Free", "free_bytes", theme.line),
        ]
    }

    var pressureColor: Color {
        switch memory.string("pressure") {
        case "critical": .red
        case "warning": .orange
        default: .green
        }
    }

    var body: some View {
        UsageCard(title: "MEMORY", meta: "PRESSURE: \((memory.string("pressure") ?? "normal").uppercased())", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(UsageFormat.bytes(memory.double("used_bytes")))
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.label)
                    Text("used of \(UsageFormat.bytes(memory.double("total_bytes")))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.sub)
                    Spacer()
                    Circle().fill(pressureColor).frame(width: 7, height: 7)
                }
                bar
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 4) {
                    ForEach(segments, id: \.key) { segment in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 8, height: 8)
                            Text(segment.label).font(.system(size: 10)).foregroundStyle(theme.sub)
                            Spacer(minLength: 2)
                            Text(UsageFormat.bytes(memory.double(segment.key)))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.label)
                        }
                    }
                    if let swap = memory.double("swap_used_bytes"), swap > 0 {
                        HStack(spacing: 5) {
                            Text("Swap").font(.system(size: 10)).foregroundStyle(theme.sub)
                            Spacer(minLength: 2)
                            Text(UsageFormat.bytes(swap))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.label)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    var bar: some View {
        let total = max(memory.double("total_bytes") ?? 1, 1)
        return GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(segments, id: \.key) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: proxy.size.width * CGFloat((memory.double(segment.key) ?? 0) / total))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .background(theme.line)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 9)
        .animation(.easeOut(duration: 0.5), value: memory.double("used_bytes"))
    }
}

/// Before/after tiles and the per-item results of an Optimize run.
struct OptimizeOutcomeCard: View {
    let outcome: OptimizeMonitor.Outcome
    let theme: DashboardTheme
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                UsageTile(
                    label: "FREED", value: outcome.freed > 0 ? UsageFormat.bytes(outcome.freed) : "0 MB", sub: nil,
                    highlight: true, theme: theme, accent: accent)
                UsageTile(
                    label: "USED",
                    value: UsageFormat.bytes(outcome.after?.double("used_bytes")),
                    sub: "was \(UsageFormat.bytes(outcome.before?.double("used_bytes")))",
                    theme: theme, accent: accent)
                UsageTile(
                    label: "FREE",
                    value: UsageFormat.bytes(outcome.after?.double("free_bytes")),
                    sub: "was \(UsageFormat.bytes(outcome.before?.double("free_bytes")))",
                    theme: theme, accent: accent)
            }
            UsageCard(title: "RESULTS", theme: theme) {
                ForEach(Array(outcome.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Rectangle().fill(theme.line).frame(height: 0.5) }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(step))
                            .font(.system(size: 12))
                            .foregroundStyle(step.ok ? Color.green : step.skipped ? Color.orange : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(theme.label)
                            Text(step.message)
                                .font(.system(size: 9.5))
                                .foregroundStyle(theme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        if step.ok, let bytes = step.bytes, bytes > 0 {
                            Text(UsageFormat.bytes(bytes))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(theme.sub)
                        }
                    }
                    .padding(10)
                }
            }
            if outcome.freed == 0 {
                Text("macOS hands memory back gradually, so the free figure can keep rising for a few seconds.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func icon(_ step: OptimizeMonitor.Step) -> String {
        step.ok ? "checkmark.circle.fill" : step.skipped ? "exclamationmark.triangle.fill" : "xmark.circle.fill"
    }
}
