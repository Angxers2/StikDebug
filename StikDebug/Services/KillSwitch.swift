//
//  KillSwitch.swift
//  StikDebug
//
//  Runs the built-in Shield tunnel (replaces LocalDevVPN) and feeds it every spoof result, so the
//  tunnel can cut the internet the moment the fake location drops (Wi-Fi lost, app killed, error)
//  and release it only once the spoof is back or the user chooses their real location.
//  Hooked in at simulate_location / clear_simulated_location, so static pins, routes, trips,
//  URL actions and Shortcuts are all covered.
//

import Foundation
import NetworkExtension
import UserNotifications

final class KillSwitch: ObservableObject {
    static let shared = KillSwitch()

    enum State: String {
        case off           // tunnel not running
        case unavailable   // couldn't install (signing without the Network Extension entitlement)
        case ready         // tunnel up, nothing spoofed
        case armed         // protecting an active spoof
        case blocked       // spoof lost: internet cut
    }

    @Published private(set) var state: State = .off
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var providerID: String { (Bundle.main.bundleIdentifier ?? "com.stik.stikdebug") + ".Shield" }

    private init() {
        NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    // MARK: Tunnel

    /// Installs (once) and connects the Shield tunnel. Safe to call repeatedly.
    @MainActor
    func start() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
            } ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerID
            proto.serverAddress = "StikDebug Shield"
            manager.protocolConfiguration = proto
            manager.localizedDescription = "StikDebug Shield"
            // Keep it always up: a down tunnel means no spoof *and* no kill switch.
            manager.onDemandRules = [NEOnDemandRuleConnect()]
            manager.isOnDemandEnabled = true
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager

            if manager.connection.status == .disconnected || manager.connection.status == .invalid {
                try manager.connection.startVPNTunnel()
            }
            lastError = nil
            refreshStatus()
            requestNotificationPermission()
        } catch {
            lastError = error.localizedDescription
            state = .unavailable
        }
    }

    private func refreshStatus() {
        guard let manager else { return }
        if manager.connection.status != .connected {
            if state != .unavailable { state = .off }
        } else if state == .off {
            state = .ready
            send("ping")
        }
    }

    // MARK: Hooks (called from LocationSimulationCommandQueue)

    func report(spoofOK: Bool) { send(spoofOK ? "ok" : "fail") }

    func disarm() { send("disarm") }

    private func send(_ message: String) {
        DispatchQueue.main.async {
            guard let session = self.manager?.connection as? NETunnelProviderSession,
                  session.status == .connected else { return }
            try? session.sendProviderMessage(Data(message.utf8)) { reply in
                guard let reply, let new = State(rawValue: String(decoding: reply, as: UTF8.self)) else { return }
                DispatchQueue.main.async { self.apply(new) }
            }
        }
    }

    private func apply(_ new: State) {
        let old = state
        state = new
        if new == .blocked, old != .blocked {
            notify("Location spoof lost: internet blocked",
                   "Your real location can't leak. Rejoin Wi-Fi to resume, or tap Stop to use your real location.")
        } else if old == .blocked, new == .armed {
            notify("Spoof restored", "Internet is back on.")
        } else if old == .blocked, new == .ready {
            notify("Using real location", "Kill switch released.")
        }
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "killswitch", content: content, trigger: nil)
        )
    }
}
