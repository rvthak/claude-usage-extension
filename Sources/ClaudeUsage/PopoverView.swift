import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var service: UsageService
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            Divider()
            HStack {
                Button(action: onRefresh) {
                    Text(service.snapshot.isLoading ? "Refreshing…" : "Refresh")
                }
                .disabled(service.snapshot.isLoading)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    @ViewBuilder
    private var content: some View {
        if let error = service.snapshot.error {
            Text(errorTitle).font(.headline).foregroundColor(.red)
            if let hint = errorHint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        } else if service.snapshot.lastUpdated == nil {
            Text("Loading…").foregroundColor(.secondary)
        } else {
            row(label: "5h",
                utilization: service.snapshot.fiveHourUtilization,
                resetAt: service.snapshot.fiveHourResetAt)
            row(label: "7d",
                utilization: service.snapshot.sevenDayUtilization,
                resetAt: service.snapshot.sevenDayResetAt)
        }
    }

    private var errorTitle: String {
        if service.snapshot.isAuthError {
            return service.snapshot.loggedOut ? "Sign-in needed" : "Token refreshing"
        }
        if service.snapshot.isRateLimited { return "Rate limited" }
        return "Error"
    }

    private var errorHint: String? {
        if service.snapshot.isAuthError {
            // Distinguish the two auth states the CLI reports for us: a genuine
            // sign-out needs the user to act; a stale token resolves on its own.
            return service.snapshot.loggedOut
                ? "Claude Code is signed out. Run `claude /login` in a terminal, then hit Refresh."
                : "Claude Code's token is stale; it refreshes the next time you run any Claude Code command. No action needed."
        }
        if service.snapshot.isRateLimited {
            return "Too many requests — backing off automatically. Try again in a few minutes."
        }
        return nil
    }

    private func row(label: String, utilization: Int, resetAt: Date?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .frame(width: 26, alignment: .leading)
            Text("\(utilization)%")
                .font(.system(.body, design: .monospaced).bold())
                .frame(width: 44, alignment: .leading)
            if let resetAt = resetAt {
                Text("in \(countdown(to: resetAt))")
                    .font(.system(.body, design: .monospaced))
                Text("(\(absolute(resetAt)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func countdown(to date: Date) -> String {
        let interval = date.timeIntervalSince(Date())
        if interval <= 0 { return "now" }
        let total = Int(interval)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func absolute(_ date: Date) -> String {
        let interval = date.timeIntervalSince(Date())
        let f = DateFormatter()
        f.dateFormat = interval > 86400 ? "EEE h:mm a" : "h:mm a"
        return f.string(from: date)
    }
}
