import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let service = UsageService()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private let normalInterval: TimeInterval = 10 * 60
    private let backoffInterval: TimeInterval = 15 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "—"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 140)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(service: service, onRefresh: { [weak self] in self?.refresh() })
        )

        service.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.updateStatusBarTitle(snapshot)
            }
            .store(in: &cancellables)

        refresh()
    }

    private func updateStatusBarTitle(_ snapshot: UsageSnapshot) {
        guard let button = statusItem.button else { return }
        if snapshot.error != nil {
            button.title = "!"
        } else if snapshot.lastUpdated != nil {
            button.title = "5h \(snapshot.fiveHourUtilization)% · 7d \(snapshot.sevenDayUtilization)%"
        } else {
            button.title = "—"
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func refresh() {
        Task { @MainActor in
            await service.fetch()
            self.scheduleNextRefresh()
        }
    }

    private func scheduleNextRefresh() {
        timer?.invalidate()
        let interval = service.snapshot.isRateLimited ? backoffInterval : normalInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }
}
