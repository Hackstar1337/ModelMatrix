import SwiftUI

/// The "Other apps using memory" list of the menu bar Optimize panel: pick
/// apps (or all of them) to quit along with the rest of the run.
extension OptimizePanelView {
    @ViewBuilder var appsCard: some View {
        if !monitor.apps.isEmpty {
            let picked = monitor.chosenApps.count
            UsageCard(title: "OTHER APPS USING MEMORY", meta: picked > 0 ? "\(picked) selected" : nil, theme: theme) {
                if !monitor.quittableApps.isEmpty {
                    selectAllRow
                    Rectangle().fill(theme.line).frame(height: 0.5)
                }
                ForEach(Array(monitor.apps.enumerated()), id: \.offset) { index, app in
                    if index > 0 { Rectangle().fill(theme.line).frame(height: 0.5) }
                    appRow(app)
                }
            }
            Text("Optimize never picks apps for you. Selected apps close the way they do with ⌘Q, so they can still ask to save your work.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var selectAllRow: some View {
        let total = monitor.quittableApps.reduce(0) { $0 + ($1.double("bytes") ?? 0) }
        let icon =
            monitor.allAppsSelected ? "checkmark.square.fill" : monitor.chosenApps.isEmpty ? "square" : "minus.square.fill"
        return Button { monitor.toggleAllApps() } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(monitor.chosenApps.isEmpty ? theme.faint : accent)
                    .frame(width: 14)
                Text(monitor.allAppsSelected ? "Clear selection" : "Select all apps that can quit (\(monitor.quittableApps.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.label)
                Spacer(minLength: 4)
                Text(UsageFormat.bytes(total))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.sub)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(monitor.isBusy)
    }

    func appRow(_ app: JSONRow) -> some View {
        let path = app.string("path") ?? ""
        let quittable = app.bool("quittable") && !path.isEmpty
        let checked = quittable && monitor.selectedApps.contains(path)
        let processes = app.int("processes") ?? 1
        let reason = quittable ? nil : (app.string("reason") ?? "system or command-line")
        let row = HStack(spacing: 9) {
            Image(systemName: quittable ? (checked ? "checkmark.square.fill" : "square") : "lock")
                .font(.system(size: quittable ? 13 : 10.5))
                .foregroundStyle(checked ? accent : theme.faint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.string("name") ?? "App")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(quittable ? theme.label : theme.sub)
                    .lineLimit(1)
                Text("\(processes) process\(processes == 1 ? "" : "es")\(reason.map { " · \($0)" } ?? "")")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.sub)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(UsageFormat.bytes(app.double("bytes")))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.sub)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(checked ? accent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        return Group {
            if quittable {
                Button { monitor.toggleApp(path) } label: { row }
                    .buttonStyle(.plain)
                    .disabled(monitor.isBusy)
            } else {
                row
            }
        }
    }

    /// Shown before a run that quits apps, listing them by name.
    var confirmBox: some View {
        let names = monitor.chosenApps.compactMap { $0.string("name") }
        let listed = names.count > 4 ? names.prefix(4).joined(separator: ", ") + " and \(names.count - 4) more" : names.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 6) {
            Text("Quit \(listed)?")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.label)
                .fixedSize(horizontal: false, vertical: true)
            Text("Each app closes the way it does with ⌘Q and can still ask you to save your work.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                SettingsLinkButton(title: "Cancel", theme: theme, accent: accent) { confirmingApps = false }
                SettingsLinkButton(title: "Quit & Optimize", emphasized: true, theme: theme, accent: .red) {
                    confirmingApps = false
                    Task { await monitor.run() }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.07)))
    }
}
