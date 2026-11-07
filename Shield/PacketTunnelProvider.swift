//
//  PacketTunnelProvider.swift
//  Shield
//
//  Replaces LocalDevVPN and adds a location kill switch.
//
//  Normal: only 10.7.0.1 is routed here and reflected back to the device (how StikDebug reaches
//  lockdownd on-device), everything else bypasses the tunnel.
//  Blocked: the default routes (v4 + v6) and DNS are pulled into the tunnel and dropped, so no app
//  can upload the real location while the spoof is down. 10.7.0.1 keeps working, so the app can
//  re-establish the spoof, and only then is the internet released.
//
//  Messages from the app: "ok" (spoof just confirmed), "fail" (spoof update failed),
//  "disarm" (user chose the real location). Reply: "ready" | "armed" | "blocked".
//

import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let deviceIP = "10.7.0.0"
    private let fakeIP = "10.7.0.1"
    private lazy var deviceValue = Self.ipValue(deviceIP)
    private lazy var fakeValue = Self.ipValue(fakeIP)

    private let queue = DispatchQueue(label: "shield")
    private var armed = false        // a spoof has been confirmed and not intentionally cleared
    private var blocked = false
    private var lastOK = Date.distantPast
    private var onWiFi = true
    private let monitor = NWPathMonitor()
    private var watchdog: DispatchSourceTimer?

    /// The app confirms the spoof at least every 4 s (static resend) or 1 s (trips/routes).
    private let heartbeatTimeout: TimeInterval = 9

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setTunnelNetworkSettings(settings(blocked: false)) { error in
            guard error == nil else { return completionHandler(error) }
            self.readPackets()
            self.startWatching()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        monitor.cancel()
        watchdog?.cancel()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async {
            switch String(decoding: messageData, as: UTF8.self) {
            case "ok":
                self.armed = true
                self.lastOK = Date()
                if self.blocked { self.setBlocked(false) }
            case "fail":
                if self.armed { self.setBlocked(true) }
            case "disarm":
                self.armed = false
                if self.blocked { self.setBlocked(false) }
            default:
                break
            }
            let state = self.blocked ? "blocked" : (self.armed ? "armed" : "ready")
            completionHandler?(Data(state.utf8))
        }
    }

    // MARK: - Kill switch

    private func startWatching() {
        // Leaving Wi-Fi is what kills the spoof (lockdownd stops accepting), so block on that edge
        // right away instead of waiting for the app's next failed update.
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wifi = path.availableInterfaces.contains { $0.type == .wifi }
            if self.onWiFi, !wifi, self.armed, !self.blocked { self.setBlocked(true) }
            self.onWiFi = wifi
        }
        monitor.start(queue: queue)

        // App killed / suspended: the spoof is gone with it.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.armed, !self.blocked else { return }
            if Date().timeIntervalSince(self.lastOK) > self.heartbeatTimeout { self.setBlocked(true) }
        }
        timer.resume()
        watchdog = timer
    }

    /// Call on `queue`.
    private func setBlocked(_ block: Bool) {
        blocked = block
        NSLog("Shield: \(block ? "BLOCKING internet" : "internet released")")
        setTunnelNetworkSettings(settings(blocked: block)) { error in
            if let error { NSLog("Shield: settings failed: \(error.localizedDescription)") }
        }
    }

    private func settings(blocked: Bool) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: deviceIP)
        // /32s so the utun never claims the LAN subnet (iOS 26.4+ lockdown subnet check).
        let ipv4 = NEIPv4Settings(addresses: [deviceIP], subnetMasks: ["255.255.255.255"])
        let peer = NEIPv4Route(destinationAddress: fakeIP, subnetMask: "255.255.255.255")
        if blocked {
            ipv4.includedRoutes = [peer, .default()]
            let ipv6 = NEIPv6Settings(addresses: ["fd07::1"], networkPrefixLengths: [128])
            ipv6.includedRoutes = [.default()]
            settings.ipv6Settings = ipv6
            // All DNS goes to the reflected peer, where nothing listens: lookups fail fast.
            let dns = NEDNSSettings(servers: [fakeIP])
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        } else {
            ipv4.includedRoutes = [peer]
            ipv4.excludedRoutes = [.default()]
        }
        settings.ipv4Settings = ipv4
        return settings
    }

    // MARK: - Packets

    /// Reflects traffic for the fake peer back to the device; drops everything else (only
    /// routed here while blocked).
    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            let fake = self.fakeValue, device = self.deviceValue
            var out: [Data] = []
            var outProtocols: [NSNumber] = []
            for i in packets.indices where protocols[i].int32Value == AF_INET && packets[i].count >= 20 {
                var packet = packets[i]
                let reflect: Bool = packet.withUnsafeMutableBytes { bytes in
                    guard let header = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return false }
                    guard UInt32(bigEndian: header[4]) == fake else { return false }
                    // Swapping src/dst keeps the IP and TCP/UDP checksums valid.
                    if UInt32(bigEndian: header[3]) == device { header[3] = fake.bigEndian }
                    header[4] = device.bigEndian
                    return true
                }
                if reflect {
                    out.append(packet)
                    outProtocols.append(protocols[i])
                }
            }
            if !out.isEmpty { self.packetFlow.writePackets(out, withProtocols: outProtocols) }
            self.readPackets()
        }
    }

    private static func ipValue(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
    }
}
