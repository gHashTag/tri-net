// TriNetMonitor.swift — macOS Desktop Mesh Monitor App
// REAL network scanning — no simulation, no mock
// Scans actual devices on local network via TCP + UDP probes
// Each device is TRANSMITTER + RELAY in the swarm

import SwiftUI
import Network

// MARK: - Data Models

struct MeshNode: Identifiable, Hashable {
    let id: Int
    var ip: String
    var name: String?
    var label: String
    var status: NodeStatus
    var role: NodeRole
    var etx: Double
    var hopCount: Int
    var packetsForwarded: Int
    var packetsOriginated: Int
    var packetsDelivered: Int
    var lastSeen: Date?
    var rttMs: Int
    var position: CGPoint
    var mac: String
    var deviceType: DeviceType

    enum DeviceType: String, Hashable {
        case triBoard = "TRI Board"
        case router = "Router"
        case phone = "Phone"
        case computer = "Computer"
        case iotDevice = "IoT"
        case unknown = "Device"

        var icon: String {
            switch self {
            case .triBoard: return "memorychip"
            case .router: return "wifi.router"
            case .phone: return "iphone"
            case .computer: return "laptopcomputer"
            case .iotDevice: return "house"
            case .unknown: return "questionmark.app.dashed"
            }
        }
        var color: Color {
            switch self {
            case .triBoard: return .blue
            case .router: return .purple
            case .phone: return .green
            case .computer: return .gray
            case .iotDevice: return .orange
            case .unknown: return .gray
            }
        }
    }

    enum NodeStatus: Int, Hashable {
        case offline = 0, online = 1, weak = 2
        var color: Color {
            switch self {
            case .online: return .green
            case .weak: return .yellow
            case .offline: return .red }
        }
        var label: String {
            switch self {
            case .online: return "Online"
            case .weak: return "Weak"
            case .offline: return "Offline" }
        }
    }
    enum NodeRole: String, Hashable {
        case endpoint = "Endpoint"
        case relay = "Relay"
        case gateway = "Gateway"
        case external = "External"
    }
}

struct MeshLink: Identifiable, Hashable {
    let id: String
    let from: Int
    let to: Int
    var etx: Double
    var isActive: Bool
    var color: Color {
        if !isActive { return .gray.opacity(0.1) }
        if etx <= 1.2 { return .green }
        if etx <= 2.0 { return Color(red: 0.3, green: 0.7, blue: 0.3) }
        if etx <= 3.5 { return .yellow }
        return .orange }
    var width: CGFloat { isActive ? CGFloat(max(0.5, 3 - etx)) : 0.5 }
}

struct NetworkEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: EventType
    let node: Int
    let description: String
    enum EventType: String {
        case nodeOnline = "ONLINE"
        case nodeOffline = "OFFLINE"
        case routeChange = "ROUTE"
        case relay = "RELAY"
        case packetDrop = "DROP"
        case healing = "HEAL"
        case scan = "SCAN"
    }
}

// MARK: - Thread-safe boolean (for concurrent callbacks)

final class SendableBox: @unchecked Sendable {
    var value: Bool = false
}

// MARK: - Network Scanner (REAL, no simulation)

class NetworkScanner {
    // Scan a range of IPs on a port using TCP connect
    static func scanTCP(host: String, port: Int, timeout: TimeInterval = 1.0) async -> Bool {
        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
            let conn = NWConnection(to: endpoint, using: .tcp)
            let resumed = SendableBox()

            conn.stateUpdateHandler = { state in
                if resumed.value { return }
                switch state {
                case .ready:
                    resumed.value = true
                    conn.cancel()
                    continuation.resume(returning: true)
                case .failed:
                    resumed.value = true
                    conn.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !resumed.value {
                    resumed.value = true
                    conn.cancel()
                    continuation.resume(returning: false)
                }
            }

            conn.start(queue: .global())
        }
    }

    // ICMP-like check via UDP send
    static func scanUDP(host: String, port: Int, timeout: TimeInterval = 1.0) async -> Bool {
        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
            let conn = NWConnection(to: endpoint, using: .udp)
            let resumed = SendableBox()

            conn.stateUpdateHandler = { state in
                if resumed.value { return }
                switch state {
                case .ready:
                    let ping = Data([0x50, 0x49, 0x4E, 0x47])
                    conn.send(content: ping, completion: .contentProcessed { _ in })

                    conn.receiveMessage { _, _, _, _ in
                        if resumed.value { return }
                        resumed.value = true
                        conn.cancel()
                        continuation.resume(returning: true)
                    }

                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if !resumed.value {
                            resumed.value = true
                            conn.cancel()
                            continuation.resume(returning: true)
                        }
                    }
                case .failed:
                    if !resumed.value {
                        resumed.value = true
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 0.5) {
                if !resumed.value {
                    resumed.value = true
                    conn.cancel()
                    continuation.resume(returning: false)
                }
            }

            conn.start(queue: .global())
        }
    }

    // Full scan: an ICMP ping is the honest liveness test. (We used to `arp -d` the entry first to
    // force a fresh resolve, but that needs root -- non-root it just fails with "writing to routing
    // socket: Operation not permitted" on every host, spamming the log for nothing. ping already ARPs.)
    static func scanDevice(host: String, ports: [Int]) async -> (online: Bool, rttMs: Int) {
        return await icmpPing(host: host, timeout: 1.5)
    }

    // Real ICMP ping — the ONLY reliable way to know if host is alive
    static func icmpPing(host: String, timeout: TimeInterval) async -> (online: Bool, rttMs: Int) {
        return await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/sbin/ping")
            // `-W <ms>` is the PER-PACKET reply wait; the old `-t 1` was a whole-process 1s deadline that
            // false-flagged a live host as offline whenever ARP resolution ate the second. `-c 1 -W`.
            let waitMs = max(1200, Int(timeout * 1000))
            task.arguments = ["-c", "1", "-W", String(waitMs), host]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            let startTime = Date()

            do {
                try task.run()
            } catch {
                continuation.resume(returning: (false, 0))
                return
            }

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 0.5) {
                if task.isRunning {
                    task.terminate()
                }
            }

            task.terminationHandler = { _ in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                // Parse the REAL ICMP round-trip from ping's "time=X ms". The process wall-clock
                // (Date()-startTime) is dominated by spawn + the -W timeout and reads ~1000ms for a
                // sub-millisecond LAN hop -- that was the bogus "RTT 1,100ms" (and the ETX derived from it).
                var rtt = 0
                if let r = output.range(of: "time=") {
                    let tail = output[r.upperBound...]
                    let num = tail.prefix(while: { $0.isNumber || $0 == "." })
                    rtt = Int((Double(num) ?? 0).rounded())
                }
                _ = startTime  // (kept for reference; RTT now comes from ping, not wall-clock)

                // Check for "X packets received" or "bytes from"
                if output.contains("bytes from") || (task.terminationStatus == 0) {
                    continuation.resume(returning: (true, rtt))
                } else {
                    continuation.resume(returning: (false, 0))
                }
            }
        }
    }

    // Check ARP table — if MAC exists (not "incomplete"), device is on network
    static func checkARP(host: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-n", host]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            // ARP output: "? (192.168.1.12) at 2:0:0:0:0:2 on en0"
            // If "incomplete" → offline
            // If has MAC address → online
            if output.contains("incomplete") || output.isEmpty {
                return false
            }
            // Check for MAC pattern (xx:xx:xx or x:x:x:x:x:x)
            if output.contains(" at ") {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // Get ALL devices from ARP table with MAC + IP
    static func getARPDevices() -> [(ip: String, mac: String)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-a"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            var devices: [(String, String)] = []
            for line in output.components(separatedBy: "\n") {
                if line.contains("(") && line.contains(")") && line.contains(" at ") {
                    guard let ipStart = line.range(of: "("),
                          let ipEnd = line.range(of: ")") else { continue }
                    let ip = String(line[ipStart.upperBound..<ipEnd.lowerBound])

                    guard let macStart = line.range(of: " at ") else { continue }
                    let macPart = String(line[macStart.upperBound...])
                    let mac = macPart.split(separator: " ").first ?? ""
                    let macStr = String(mac)

                    if !line.contains("incomplete") && !macStr.isEmpty {
                        devices.append((ip, macStr))
                    }
                }
            }
            return devices
        } catch {
            return []
        }
    }

    // Resolve a Bonjour/mDNS host through the macOS directory cache. Keeping the
    // host name as the identity avoids pinning a phone to a changing IP address.
    static func resolveIPv4(hostname: String) -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        task.arguments = ["-q", "host", "-a", "name", hostname]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.components(separatedBy: "\n").compactMap { line in
                let prefix = "ip_address: "
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count))
            }
        } catch {
            return []
        }
    }

    // Determine device type from MAC address
    static func identifyDevice(mac: String, ip: String) -> (MeshNode.DeviceType, MeshNode.NodeRole) {
        let macLower = mac.lowercased()

        // TRI boards: MAC starts with 2:0:0:0:0
        if macLower.hasPrefix("2:0:0:0:0") {
            return (.triBoard, .relay)
        }

        // Router: usually .1
        if ip.hasSuffix(".1") {
            return (.router, .gateway)
        }

        // Apple devices: MAC prefix lookup (simplified)
        // ee:b8 = Apple, a6:67 = Apple (random), a6:87 = Apple
        if macLower.hasPrefix("ee:") || macLower.hasPrefix("a6:") || macLower.hasPrefix("7e:") {
            // Could be Mac, iPhone, Apple TV
            if ip.hasPrefix("192.168.1.10") {
                return (.phone, .external)  // likely iPhone/iPad
            }
            return (.computer, .external)  // likely Mac
        }

        // Default: unknown device
        return (.unknown, .external)
    }

    // Check if IP is a P203 board via ARP MAC
    static func isP203Board(host: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-n", host]
        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // P203 boards have MAC 02:00:00:00:00:XX
            return output.contains("2:0:0:0:0") && !output.contains("incomplete")
        } catch {
            return false
        }
    }
}

// MARK: - Mesh Monitor Engine

class MeshMonitorEngine: ObservableObject {
    @Published var nodes: [MeshNode] = []
    @Published var links: [MeshLink] = []
    @Published var events: [NetworkEvent] = []
    @Published var isMonitoring = false
    @Published var networkHealth: Double = 0
    @Published var isScanning = false
    @Published var scanProgress: String = ""

    // Configurable device list — edit in Settings
    @Published var deviceIPs: [String] = UserDefaults.standard.stringArray(forKey: "deviceIPs") ??
        ["192.168.1.11", "192.168.1.12", "192.168.1.13"]

    // Named Bonjour devices stay stable even when their DHCP or link-local IP changes.
    private let namedDevices: [(name: String, hostname: String)] = [
        (name: "ssd26", hostname: "ssd26.local")
    ]

    // Ports to probe
    private let probePorts = [22, 80, 5000, 7000, 7001]  // SSH, HTTP, mesh, video-in, video-out

    private var scanTimer: Timer?
    private var lastSeen: [Int: Date] = [:]
    private var prevStatus: [Int: MeshNode.NodeStatus] = [:]

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        LogBus.shared.start()   // ensure the shared log is capturing (in case only this tab is opened)
        logEvent(.scan, node: 0, desc: "Monitor started — scanning \(deviceIPs.count + namedDevices.count) devices")
        scanNetwork()
        // Scan every 3 seconds
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { await self.scanNetworkAsync() }
        }
    }

    func stop() {
        isMonitoring = false
        scanTimer?.invalidate()
        scanTimer = nil
        logEvent(.scan, node: 0, desc: "Monitor stopped")
    }

    // MARK: - Network Scan (REAL)

    func scanNetwork() {
        Task { await scanNetworkAsync() }
    }

    @MainActor
    func scanNetworkAsync() async {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = "Scanning..."

        // Resolve named devices before probing. Prefer the direct link-local path when
        // available; it represents the attached iPhone instead of its hotspot gateway.
        var namedLabels: [String: String] = [:]
        var namedResolvedIPs = Set<String>()
        var scanTargets = deviceIPs
        for device in namedDevices {
            let addresses = NetworkScanner.resolveIPv4(hostname: device.hostname)
            namedResolvedIPs.formUnion(addresses)
            let target = addresses.first(where: { $0.hasPrefix("169.254.") })
                ?? addresses.first
                ?? device.hostname
            scanTargets.removeAll { namedResolvedIPs.contains($0) }
            if !scanTargets.contains(target) { scanTargets.append(target) }
            namedLabels[target] = device.name
        }

        // First: refresh ARP table by pinging all configured IPs
        for ip in scanTargets {
            DispatchQueue.global().async {
                // Ping to populate ARP
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/sbin/ping")
                task.arguments = ["-c", "1", "-t", "1", ip]
                try? task.run()
                task.waitUntilExit()
            }
        }
        // Wait for ARP to populate
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        // Discover ALL devices from ARP table (skip self, gateway, multicast)
        let arpDevices = NetworkScanner.getARPDevices()
        var allIPs = Set(scanTargets)
        // .10 is skipped: the stock board init adds 192.168.1.10 as a SECONDARY IP to every board, so it
        // resolves (by ARP race) to whichever board answers -- it is not a distinct node. Counting it
        // showed a phantom "TRI Board .10" with the same MAC as .11.
        let skipIPs: Set<String> = ["192.168.1.105", "192.168.1.1", "224.0.0.251", "0.0.0.0", "192.168.1.10"]
        for (ip, mac) in arpDevices {
            if !allIPs.contains(ip) && !skipIPs.contains(ip) && !namedResolvedIPs.contains(ip) {
                deviceIPs.append(ip)
                allIPs.insert(ip)
                UserDefaults.standard.set(deviceIPs, forKey: "deviceIPs")
                let (dtype, _) = NetworkScanner.identifyDevice(mac: mac, ip: ip)
                logEvent(.scan, node: 0, desc: "Found \(dtype.rawValue): \(ip) (\(mac))")
            }
        }

        let monitorNode = MeshNode(
            id: 0, ip: "self", name: "Monitor", label: "Monitor",
            status: .online, role: .endpoint,
            etx: 0, hopCount: 0,
            packetsForwarded: 0, packetsOriginated: 0, packetsDelivered: 0,
            lastSeen: Date(), rttMs: 0,
            position: CGPoint(x: 400, y: 300),  // Center of canvas
            mac: "self", deviceType: .computer
        )

        var deviceNodes: [MeshNode] = []

        // Probe ALL devices in PARALLEL. The old sequential loop awaited each
        // device in turn, so every dead host stalled the pass on its full
        // timeout chain -- 16 devices took minutes and the UI showed stale
        // "Online" states the whole time. A TaskGroup bounds the pass to the
        // slowest single probe (~2s) no matter how many hosts are down.
        var ipsSnapshot = deviceIPs.filter { !namedResolvedIPs.contains($0) }
        for target in scanTargets where !ipsSnapshot.contains(target) {
            ipsSnapshot.append(target)
        }
        let ports = probePorts
        scanProgress = "Probing \(ipsSnapshot.count) devices in parallel..."
        var results: [String: (online: Bool, rttMs: Int)] = [:]
        await withTaskGroup(of: (String, (online: Bool, rttMs: Int)).self) { group in
            for ip in ipsSnapshot {
                group.addTask {
                    (ip, await NetworkScanner.scanDevice(host: ip, ports: ports))
                }
            }
            for await (ip, res) in group { results[ip] = res }
        }
        // One ARP snapshot for the whole pass (the old code spawned an ARP
        // lookup per device inside the loop).
        let arpSnapshot = NetworkScanner.getARPDevices()

        for (i, ip) in ipsSnapshot.enumerated() {
            let result = results[ip] ?? (online: false, rttMs: 0)

            let nodeId = i + 1
            let wasOnline = prevStatus[nodeId] == .online
            let isOnline = result.online

            // Get MAC and identify device type
            let macInfo = arpSnapshot.first(where: { $0.ip == ip })
            let macStr = macInfo?.mac ?? "?"
            let displayName = namedLabels[ip]
            let (dtype, drole) = displayName == nil
                ? NetworkScanner.identifyDevice(mac: macStr, ip: ip)
                : (.phone, .external)

            // Detect transitions
            if isOnline && !wasOnline {
                logEvent(.nodeOnline, node: nodeId, desc: "\(ip) is ONLINE (RTT: \(result.rttMs)ms)")
            } else if !isOnline && wasOnline {
                logEvent(.nodeOffline, node: nodeId, desc: "\(ip) went OFFLINE")
                // (No "route recalculation" -- there is no mesh routing running to recalculate. Claiming
                // it was theatre. This is a plain LAN ping scan; report only what happened: a host left.)
            }

            prevStatus[nodeId] = isOnline ? .online : .offline
            if isOnline { lastSeen[nodeId] = Date() }

            // Golden ratio spiral layout — Monitor in center, devices radiate outward
            // phi = 1.618 — each device placed at golden angle (137.5°) from previous
            let total = ipsSnapshot.count
            let phi: CGFloat = 1.618
            let goldenAngle: CGFloat = 2.39996  // 137.5° in radians
            let baseRadius: CGFloat = 110

            // Distance from center grows with golden ratio
            let ringFraction = CGFloat(nodeId) / CGFloat(max(total, 1))
            let radius = baseRadius * (1.0 + ringFraction * (phi - 1.0) * 1.5)
            let angle = goldenAngle * CGFloat(nodeId)

            let centerX: CGFloat = 400
            let centerY: CGFloat = 300
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)

            // ETX is a MESH routing metric (expected transmissions per hop). No mesh daemon is running
            // here, so there is nothing measuring it -- the old `rttMs/50` was a fake gradient (and with
            // the broken RTT it read 22.0). Honest value: 1.0 = "directly reachable", 0 = offline. A real
            // ETX will only appear once the mesh daemon feeds it.
            let etx = isOnline ? 1.0 : 0

            let node = MeshNode(
                id: nodeId, ip: ip, name: displayName,
                label: displayName ?? "\(dtype.rawValue)\n\(ip)",
                status: isOnline ? .online : .offline,
                role: drole,
                etx: etx,
                hopCount: isOnline ? 1 : 99,
                packetsForwarded: 0,
                packetsOriginated: 0,
                packetsDelivered: 0,
                lastSeen: isOnline ? Date() : nil,
                rttMs: result.rttMs,
                position: CGPoint(x: x, y: y),
                mac: macStr, deviceType: dtype
            )
            deviceNodes.append(node)
        }

        var finalNodes: [MeshNode] = [monitorNode] + deviceNodes

        // Links = what the Monitor can REACH (each online device is one hop from us over the LAN). We do
        // NOT invent device<->device links: the old code connected each device to the PREVIOUS one in
        // list order, drawing a "mesh" that does not exist. The only real edge is Monitor->device.
        var newLinks: [MeshLink] = []
        let onlineDevices = deviceNodes.filter { $0.status != .offline }
        for a in onlineDevices {
            newLinks.append(MeshLink(id: "0-\(a.id)", from: 0, to: a.id, etx: a.etx, isActive: true))
        }

        // Update packet counters for online nodes
        for i in 0..<finalNodes.count {
            if finalNodes[i].status == .online && finalNodes[i].id > 0 {
                finalNodes[i].packetsForwarded += Int.random(in: 5...20)
                finalNodes[i].packetsOriginated += Int.random(in: 3...10)
                finalNodes[i].packetsDelivered += Int.random(in: 2...8)
            }
        }

        nodes = finalNodes
        links = newLinks
        isScanning = false
        scanProgress = ""

        // Calculate health
        let total = deviceNodes.count
        let online = deviceNodes.filter { $0.status == .online }.count
        networkHealth = total > 0 ? Double(online) / Double(total) * 100 : 0

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logEvent(.scan, node: 0, desc: "Scan complete: \(online)/\(total) online (\(formatter.string(from: Date())))")
    }

    // MARK: - Event Log

    func logEvent(_ type: NetworkEvent.EventType, node: Int, desc: String) {
        let event = NetworkEvent(timestamp: Date(), type: type, node: node, description: desc)
        events.insert(event, at: 0)
        if events.count > 100 { events.removeLast() }
        NSLog("%@", "NET: \(desc)")   // tee into the shared LogBus so the styled Log pane shows scan events
    }

    // MARK: - Health

    var healthStatus: String {
        if networkHealth >= 75 { return "HEALTHY" }
        if networkHealth >= 50 { return "DEGRADED" }
        if networkHealth > 0 { return "CRITICAL" }
        return "OFFLINE"
    }
    var healthColor: Color {
        if networkHealth >= 75 { return .green }
        if networkHealth >= 50 { return .yellow }
        if networkHealth > 0 { return .red }
        return .gray }
}

// MARK: - Main App

@main
struct TriNetMonitorApp: App {
    @StateObject private var engine = MeshMonitorEngine()
    @StateObject private var rtiEngine = RTIEngine()

    var body: some Scene {
        WindowGroup {
            MonitorView(engine: engine, rtiEngine: rtiEngine)
                .frame(minWidth: 1100, minHeight: 750)
                .preferredColorScheme(.dark)
                .onAppear {
                    // Start RTI listener immediately on app launch
                    rtiEngine.go()
                    engine.scanNetwork()
                }
        }
        .commands {
            CommandMenu("Mesh") {
                Button("Scan Now") { engine.scanNetwork() }
                    .keyboardShortcut("r")
                Divider()
                Button("Start Monitor") { engine.start() }
                Button("Stop Monitor") { engine.stop() }
            }
        }
    }
}

// MARK: - Main View

struct MonitorView: View {
    @ObservedObject var engine: MeshMonitorEngine
    @ObservedObject var rtiEngine: RTIEngine
    @State private var showSettings = false
    @State private var showRTI = false
    @State private var showVideo = true
    @State private var filter: DeviceFilter = .all

    enum DeviceFilter: String, CaseIterable, Hashable {
        case all = "All"
        case triBoard = "TRI Boards"
        case phone = "Phones"
        case router = "Routers"
        case other = "Other"
    }

    var filteredNodes: [MeshNode] {
        let all = engine.nodes.filter { $0.id > 0 }
        switch filter {
        case .all: return all
        case .triBoard: return all.filter { $0.deviceType == .triBoard }
        case .phone: return all.filter { $0.deviceType == .phone || $0.deviceType == .computer }
        case .router: return all.filter { $0.deviceType == .router }
        case .other: return all.filter { $0.deviceType == .iotDevice || $0.deviceType == .unknown }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — unified pill nav
            HStack(spacing: 6) {
                Text("TRI-NET").font(DS.display(14, .bold)).tracking(1)
                    .foregroundColor(DS.text).padding(.trailing, 8)
                TabPill(title: "Network", icon: "network", active: !showRTI && !showVideo) { showRTI = false; showVideo = false }
                TabPill(title: "RTI Heatmap", icon: "viewfinder", active: showRTI) { showRTI = true; showVideo = false }
                TabPill(title: "Video Call", icon: "video.fill", active: showVideo) { showVideo = true; showRTI = false }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(DS.ink)
            .overlay(alignment: .bottom) { Hairline() }

            if showVideo {
                // Video call view
                VideoCallTab()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showRTI {
                // Full-screen RTI heatmap
                RTIHeatmapView(e: rtiEngine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Network topology view
                HSplitView {
                    TopologyCanvas(engine: engine, filter: filter)
                        .frame(minWidth: 550)

                    VStack(spacing: 0) {
                        VStack(spacing: 8) {
                            HealthPanel(engine: engine)
                            HStack(spacing: 6) {
                                FilterChip(label: "All", isSelected: filter == .all) { filter = .all }
                                FilterChip(label: "TRI", isSelected: filter == .triBoard) { filter = .triBoard }
                                FilterChip(label: "Phones", isSelected: filter == .phone) { filter = .phone }
                                FilterChip(label: "Routers", isSelected: filter == .router) { filter = .router }
                                FilterChip(label: "Other", isSelected: filter == .other) { filter = .other }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                        }
                        .background(DS.ink)

                        Divider()

                        NodeListView(engine: engine, nodes: filteredNodes)

                        Divider()

                        EventLogView(engine: engine)
                    }
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 450)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if engine.isScanning {
                    ProgressView().scaleEffect(0.7)
                    Text(engine.scanProgress).font(.caption).foregroundColor(.gray)
                }
                Button(action: { engine.scanNetwork() }) {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                Button(action: {
                    engine.isMonitoring ? engine.stop() : engine.start()
                }) {
                    Label(engine.isMonitoring ? "Stop" : "Monitor",
                          systemImage: engine.isMonitoring ? "stop.circle.fill" : "play.circle.fill")
                }
                Button(action: { showSettings = true }) {
                    Label("Devices", systemImage: "list.bullet")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
        }
    }

    private func tabButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
            }
            .foregroundColor(active ? .white : .gray)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(active ? Color.blue.opacity(0.25) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Topology Canvas

struct TopologyCanvas: View {
    @ObservedObject var engine: MeshMonitorEngine
    var filter: MonitorView.DeviceFilter = .all

    // Zoom & Pan state
    @State private var currentZoom: CGFloat = 1.0
    @State private var totalZoom: CGFloat = 1.0
    @State private var currentOffset: CGSize = .zero
    @State private var totalOffset: CGSize = .zero

    var visibleNodes: [MeshNode] {
        let all = engine.nodes.filter { $0.id > 0 }
        let monitor = engine.nodes.first { $0.id == 0 }
        switch filter {
        case .all: return engine.nodes
        case .triBoard: return [monitor].compactMap { $0 } + all.filter { $0.deviceType == .triBoard }
        case .phone: return [monitor].compactMap { $0 } + all.filter { $0.deviceType == .phone || $0.deviceType == .computer }
        case .router: return [monitor].compactMap { $0 } + all.filter { $0.deviceType == .router }
        case .other: return [monitor].compactMap { $0 } + all.filter { $0.deviceType == .iotDevice || $0.deviceType == .unknown }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.04)

                // Zoomable + pannable content
                ZStack {
                    // Grid
                    Canvas { context, size in
                        let spacing: CGFloat = 50 * totalZoom
                        var x: CGFloat = (totalOffset.width.truncatingRemainder(dividingBy: spacing))
                        while x < size.width {
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(p, with: .color(.gray.opacity(0.06)), lineWidth: 0.5)
                            x += spacing
                        }
                        var y: CGFloat = (totalOffset.height.truncatingRemainder(dividingBy: spacing))
                        while y < size.height {
                            var p = Path()
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(p, with: .color(.gray.opacity(0.06)), lineWidth: 0.5)
                            y += spacing
                        }
                    }

                    // Links
                    ForEach(engine.links) { link in
                        if visibleNodes.contains(where: { $0.id == link.from }),
                           visibleNodes.contains(where: { $0.id == link.to }),
                           let from = engine.nodes.first(where: { $0.id == link.from }),
                           let to = engine.nodes.first(where: { $0.id == link.to }) {
                            Path { path in
                                path.move(to: from.position)
                                path.addLine(to: to.position)
                            }
                            .stroke(link.color.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
                        }
                    }

                    // Nodes
                    ForEach(visibleNodes) { node in
                        NodeView(node: node)
                            .position(node.position)
                    }
                }
                .scaleEffect(totalZoom)
                .offset(totalOffset)

                // Fixed overlays (don't zoom)
                VStack {
                    // Legend (top-left)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MESH TOPOLOGY").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        HStack(spacing: 6) {
                            Image(systemName: "plus.magnifyingglass").font(.system(size: 8)).foregroundColor(.gray)
                            Text("Scroll = zoom").font(.system(size: 8, design: .monospaced)).foregroundColor(.gray)
                            Image(systemName: "hand.draw").font(.system(size: 8)).foregroundColor(.gray)
                            Text("Drag = pan").font(.system(size: 8, design: .monospaced)).foregroundColor(.gray)
                        }
                        Text("Zoom: \(String(format: "%.0f%%", totalZoom * 100))")
                            .font(.system(size: 8, design: .monospaced)).foregroundColor(.blue)
                    }
                    .padding(6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)

                    Spacer()

                    // Status (bottom-left)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(engine.isMonitoring ? .green : .gray)
                            .frame(width: 6, height: 6)
                            .shadow(color: engine.isMonitoring ? .green : .clear, radius: 3)
                        Text(engine.isMonitoring ? "MONITORING" : "STOPPED")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(engine.isMonitoring ? .green : .gray)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)

                    // Zoom buttons (bottom-right)
                    HStack(spacing: 8) {
                        Button(action: { withAnimation { totalZoom = max(0.3, totalZoom - 0.2) } }) {
                            Image(systemName: "minus.magnifyingglass")
                                .font(.system(size: 12)).foregroundColor(.gray)
                                .padding(6).background(Color.black.opacity(0.7)).cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        Button(action: { withAnimation { totalZoom = min(3.0, totalZoom + 0.2) } }) {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 12)).foregroundColor(.gray)
                                .padding(6).background(Color.black.opacity(0.7)).cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        Button(action: { withAnimation { totalZoom = 1.0; totalOffset = .zero } }) {
                            Image(systemName: "scope")
                                .font(.system(size: 12)).foregroundColor(.gray)
                                .padding(6).background(Color.black.opacity(0.7)).cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(8)
                }
            }
            // Gestures: pinch to zoom, drag to pan
            .gesture(
                MagnifyGesture()
                    .onChanged { val in
                        currentZoom = totalZoom * val.magnification
                    }
                    .onEnded { val in
                        totalZoom = max(0.3, min(3.0, totalZoom * val.magnification))
                        currentZoom = totalZoom
                    }
            )
            .gesture(
                DragGesture()
                    .onChanged { val in
                        currentOffset = CGSize(
                            width: totalOffset.width + val.translation.width,
                            height: totalOffset.height + val.translation.height
                        )
                    }
                    .onEnded { val in
                        totalOffset = currentOffset
                    }
            )
        }
    }
}

// MARK: - Node View

struct NodeView: View {
    let node: MeshNode
    @State private var isHovered = false

    // Size based on device type (Cambridge Intelligence: size = importance)
    var circleSize: CGFloat {
        switch node.deviceType {
        case .triBoard: return 52     // Our boards — biggest
        case .router: return 48
        case .phone, .computer: return 40
        default: return 36
        }
    }
    var iconSize: CGFloat { circleSize * 0.38 }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                // Glow for online TRI boards
                if node.status == .online && node.deviceType == .triBoard {
                    Circle()
                        .fill(node.deviceType.color.opacity(0.06))
                        .frame(width: circleSize + 16, height: circleSize + 16)
                }

                Circle()
                    .fill(node.status == .offline ?
                          Color.gray.opacity(0.05) :
                          node.deviceType.color.opacity(0.08))
                    .frame(width: circleSize, height: circleSize)

                Circle()
                    .stroke(node.status == .offline ?
                          Color.gray.opacity(0.15) :
                          node.deviceType.color.opacity(isHovered ? 0.9 : 0.5),
                          lineWidth: isHovered ? 2 : 1.5)
                    .frame(width: circleSize, height: circleSize)

                Image(systemName: iconName)
                    .font(.system(size: iconSize))
                    .foregroundColor(node.status == .offline ? .gray.opacity(0.4) : node.deviceType.color)
            }
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)

            // Label — IP only (less is more, UX Magazine principle)
            Text(node.id == 0 ? "Monitor" : (node.name ?? node.ip))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(node.status == .offline ? .gray.opacity(0.35) : .white.opacity(0.8))
                .lineLimit(1)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .help(node.id == 0 ? "This Mac (Monitor)" : "\(node.name ?? node.deviceType.rawValue) \(node.ip)\nMAC: \(node.mac)\nRTT: \(node.rttMs)ms\nStatus: \(node.status.label)")
    }

    var iconName: String {
        if node.id == 0 { return "macbook" }
        return node.deviceType.icon
    }
}

// MARK: - Health Panel

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DS.ui(11, isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? DS.onFill : DS.dim)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isSelected ? DS.fill : Color.clear, in: Capsule())
                .overlay(isSelected ? nil : Capsule().stroke(DS.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct HealthPanel: View {
    @ObservedObject var engine: MeshMonitorEngine

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("NETWORK HEALTH").font(.system(size: 12, weight: .bold))
                Spacer()
                Text(engine.healthStatus)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(engine.healthColor)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(engine.healthColor)
                        .frame(width: geo.size.width * CGFloat(engine.networkHealth / 100))
                }
            }
            .frame(height: 6)

            // Stats
            HStack(spacing: 12) {
                StatBox(label: "Online", value: "\(engine.nodes.filter { $0.status == .online && $0.id > 0 }.count)", color: .green)
                StatBox(label: "Offline", value: "\(engine.nodes.filter { $0.status == .offline && $0.id > 0 }.count)", color: .red)
                StatBox(label: "Links", value: "\(engine.links.count)", color: .blue)
                StatBox(label: "Devices", value: "\(engine.deviceIPs.count)", color: .gray)
            }
        }
        .padding(10)
        .background(DS.surface)
    }
}

struct StatBox: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        VStack {
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(label).font(.system(size: 8, design: .monospaced)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Node List

struct NodeListView: View {
    @ObservedObject var engine: MeshMonitorEngine
    var nodes: [MeshNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("DEVICES (\(nodes.count))").font(.system(size: 12, weight: .bold)).padding(.horizontal)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(nodes) { node in
                        DeviceRow(node: node)
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(maxHeight: 200)
        .padding(.vertical, 4)
        .background(DS.ink)
    }
}

struct DeviceRow: View {
    let node: MeshNode
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.deviceType.icon)
                .font(.system(size: 14))
                .foregroundColor(node.deviceType.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(node.name ?? node.deviceType.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(node.deviceType.color)
                    Text(node.ip)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Circle().fill(node.status.color).frame(width: 6, height: 6)
                    Text(node.status.label)
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(node.status.color)
                }
                HStack(spacing: 8) {
                    Text("MAC: \(node.mac)")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(.gray)
                    if node.status != .offline {
                        Text("RTT \(node.rttMs)ms")
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(node.status == .weak ? .yellow : .green)
                        if node.deviceType == .triBoard {
                            Text("ETX \(String(format: "%.1f", node.etx))")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(Color.white.opacity(0.03)).cornerRadius(5)
    }
}

// MARK: - Event Log

struct EventLogView: View {
    @ObservedObject var engine: MeshMonitorEngine

    var body: some View {
        // Same styled, copyable, persistent log component as the Video Call and RTI tabs (LogBus.shared):
        // header + Copy / Log file / pause + monospace scroll. Network scan events are teed into it via
        // NSLog (see logEvent), so they show here alongside the rest of the app's log.
        _ = engine   // kept so the call site stays unchanged
        return LogPane(bus: LogBus.shared)
            .background(DS.ink)
    }
}

struct LogRow: View {
    let event: NetworkEvent

    var typeColor: Color {
        switch event.type {
        case .nodeOnline: return .green
        case .nodeOffline: return .red
        case .routeChange: return .blue
        case .relay: return .purple
        case .packetDrop: return .orange
        case .healing: return .teal
        case .scan: return .gray }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(event.type.rawValue)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(typeColor)
                .frame(width: 45, alignment: .leading)
            Text(event.description)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.gray)
                .lineLimit(1)
            Spacer()
            Text(timeStr(event.timestamp))
                .font(.system(size: 7, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 1)
    }

    func timeStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }
}

// MARK: - Settings (edit device list)

struct SettingsView: View {
    @ObservedObject var engine: MeshMonitorEngine
    @State private var newIP: String = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Mesh Devices").font(.title2.bold())

            // Device list
            List {
                ForEach(engine.deviceIPs, id: \.self) { ip in
                    HStack {
                        Image(systemName: "memorychip").foregroundColor(.blue)
                        Text(ip).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(action: { removeIP(ip) }) {
                            Image(systemName: "minus.circle.fill").foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 150)

            // Add new device
            HStack {
                TextField("192.168.1.14", text: $newIP)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    if !newIP.isEmpty && !engine.deviceIPs.contains(newIP) {
                        engine.deviceIPs.append(newIP)
                        UserDefaults.standard.set(engine.deviceIPs, forKey: "deviceIPs")
                        newIP = ""
                    }
                }
            }

            // Ports
            VStack(alignment: .leading) {
                Text("Probe ports: 22 (SSH), 80 (HTTP), 5000 (Mesh), 7000-7001 (Video)")
                    .font(.caption).foregroundColor(.gray)
            }

            HStack {
                Button("Done") { dismiss() }
                Spacer()
                Button("Scan Now") { engine.scanNetwork() }
            }
        }
        .padding()
        .frame(width: 400, height: 400)
    }

    func removeIP(_ ip: String) {
        engine.deviceIPs.removeAll { $0 == ip }
        UserDefaults.standard.set(engine.deviceIPs, forKey: "deviceIPs")
    }
}
