import AppKit
import Darwin

@main
enum CodexRelayMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            return
        }

        if CommandLine.arguments.contains("--probe") {
            runProbe()
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    @MainActor
    private static func runSelfTest() {
        let failures = RateLimitWindowSelfTest.run()
            + AccountManagementSelfTest.run()
            + UpdateCheckerSelfTest.run()
        if failures.isEmpty {
            print("Codex Relay self-test: passed")
            exit(EXIT_SUCCESS)
        }

        for failure in failures {
            FileHandle.standardError.write(Data(("FAIL: \(failure)\n").utf8))
        }
        exit(EXIT_FAILURE)
    }

    private static func runProbe() {
        do {
            let result = try CodexAppServerClient().fetchAccountUsage()
            guard let limit = result.rateLimits.codexLimit else {
                throw CodexClientError.malformedResponse
            }

            let planType = limit.planType ?? result.account?.planType ?? "unknown"
            let windows = limit.displayWindows
                .map {
                    "\($0.windowDurationMins)m:\(Int($0.remainingPercent.rounded()))%"
                }
                .joined(separator: ",")
            print("plan=\(planType) windows=\(windows.isEmpty ? "none" : windows)")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(EXIT_FAILURE)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: LimitStore?
    private var panelController: DockPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = LimitStore()
        let panelController = DockPanelController(store: store)
        self.store = store
        self.panelController = panelController
        store.onNotificationOpen = { [weak store, weak panelController] destination in
            panelController?.show()
            store?.requestHUDPopover(destination)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        configureStatusItem()
        panelController.show()
        if CommandLine.arguments.contains("--expanded-preview") {
            panelController.showExpandedPreview()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.67percent",
            accessibilityDescription: "Codex Relay"
        )
        item.button?.toolTip = "Codex Relay"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Accounts…", action: #selector(showAccounts), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show / Hide", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Codex Relay", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        panelController?.toggle()
    }

    @objc private func showAccounts() {
        panelController?.show()
        store?.requestAccountPopover()
    }

    @objc private func refresh() {
        store?.refresh()
        panelController?.show()
    }

    @objc private func checkForUpdates() {
        store?.updateChecker.check()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
