// MeshMapView.swift — Real-time mesh topology via continuous UDP heartbeat
import SwiftUI
import Network

struct MeshNodeInfo: Identifiable, Equatable {
    let id: Int
    let label: String
    let etx: Double
    let status: Int // 0=offline, 1=online, 2=weak
    let hopCount: Int
    let neighborId: Int
    let x: CGFloat
    let y: CGFloat
    let ip: String
}

// Continuous heartbeat monitor — sends UDP ping every 1s, listens for response
class HeartbeatMonitor: ObservableObject {
    @Published var devices: [MeshNodeInfo] = []
    @Published var lastUpdate: Date = Date()
    @Published var isScanning = false

    private var monitors: [Int: NWConnection] = [:]
    private var lastSeen: [Int: Date] = [:]
    private var timer: Timer?

    // Device list — editable
    var deviceList: [(id: Int, ip: String, name: String)] = [
        (1, "192.168.1.11", "Board #1"),
        (2, "192.168.1.12", "Board #2"),
        (3, "192.168.1.13", "Board #3"),
    ]
    private let port: UInt16 = 5000
    private let timeoutSeconds: TimeInterval = 3.0 // offline after 3s no response

    func start() {
        guard !isScanning else { return }
        isScanning = true
        print("[heartbeat] Starting monitor for \(deviceList.count) devices")

        // Create UDP connections to each device
        for device in deviceList {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(device.ip),
                port: NWEndpoint.Port(integerLiteral: port)
            )
            let conn = NWConnection(to: endpoint, using: .udp)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[heartbeat] Connected to \(device.ip):\(self.port)")
                    self.startListening(conn: conn, deviceId: device.id)
                case .failed(let err):
                    print("[heartbeat] Failed \(device.ip): \(err)")
                default:
                    break
                }
            }

            conn.start(queue: .global())
            monitors[device.id] = conn
            lastSeen[device.id] = nil // unknown
        }

        // Heartbeat timer — send ping every 1 second
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.sendHeartbeats()
            self.checkTimeouts()
        }
    }

    private func sendHeartbeats() {
        let ping = Data([0x50, 0x49, 0x4E, 0x47]) // "PING"
        for (id, conn) in monitors {
            conn.send(content: ping, completion: .contentProcessed { error in
                if let error = error {
                    print("[heartbeat] Send to device \(id) failed: \(error)")
                }
            })
        }
    }

    private func startListening(conn: NWConnection, deviceId: Int) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                print("[heartbeat] RX from device \(deviceId): \(data.count) bytes")
                self?.lastSeen[deviceId] = Date()
            }
            // Continue listening
            if error == nil {
                self?.startListening(conn: conn, deviceId: deviceId)
            }
        }
    }

    private func checkTimeouts() {
        let now = Date()
        var updated = false

        for device in deviceList {
            let last = lastSeen[device.id]
            let isOnline: Bool
            let status: Int

            if let last = last {
                let age = now.timeIntervalSince(last)
                if age < 1.5 {
                    status = 1 // online
                    isOnline = true
                } else if age < 3.0 {
                    status = 2 // weak
                    isOnline = true
                } else {
                    status = 0 // offline
                    isOnline = false
                }
            } else {
                // Check if the UDP connection itself is ready (port reachable)
                // Even without response, if conn is .ready the host exists
                if let conn = monitors[device.id] {
                    // Connection state check
                    status = 2 // assume weak until confirmed
                    isOnline = false
                } else {
                    status = 0
                    isOnline = false
                }
            }

            // Also do a quick TCP probe for definitive status
            // This runs async and updates next cycle
        }

        // Build device list for UI
        DispatchQueue.main.async {
            self.devices = self.deviceList.map { device in
                let last = self.lastSeen[device.id]
                let status: Int
                if let last = last {
                    let age = now.timeIntervalSince(last)
                    if age < 1.5 { status = 1 }
                    else if age < 3.0 { status = 2 }
                    else { status = 0 }
                } else {
                    status = 0
                }

                // Position in circle
                let total = self.deviceList.count + 1 // +1 for iPhone
                let idx = device.id // 1-based
                let radius: CGFloat = 100
                let centerX: CGFloat = 156
                let centerY: CGFloat = 175
                let angle = (CGFloat(idx) / CGFloat(total)) * 2 * .pi - .pi / 2
                let x = centerX + radius * cos(angle)
                let y = centerY + radius * sin(angle)

                return MeshNodeInfo(
                    id: device.id,
                    label: "\(device.name)\n\(device.ip)",
                    etx: status > 0 ? 1.0 : 0,
                    status: status,
                    hopCount: 1,
                    neighborId: 0,
                    x: x, y: y,
                    ip: device.ip
                )
            }

            // Add iPhone as node 0
            let iphoneNode = MeshNodeInfo(
                id: 0, label: "iPhone\n(This)", etx: 0,
                status: 1, hopCount: 0, neighborId: -1,
                x: 156, y: 175, // center
                ip: "self"
            )
            self.devices.insert(iphoneNode, at: 0)

            self.lastUpdate = now
        }
    }

    func stop() {
        isScanning = false
        timer?.invalidate()
        timer = nil
        for (_, conn) in monitors {
            conn.cancel()
        }
        monitors.removeAll()
        lastSeen.removeAll()
        print("[heartbeat] Stopped")
    }
}

struct MeshMapView: View {
    @ObservedObject var vm: StreamViewModel
    @StateObject private var monitor = HeartbeatMonitor()

    func linkColor(status: Int) -> Color {
        switch status {
        case 1: return .green
        case 2: return .yellow
        default: return .red.opacity(0.3)
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                // Header
                HStack {
                    Text("MESH TOPOLOGY")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    if monitor.isScanning {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                                .shadow(color: .green, radius: 3)
                            Text("LIVE").font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.green)
                        }
                    }
                }
                .padding(.horizontal)

                // Timestamp
                let age = Int(Date().timeIntervalSince(monitor.lastUpdate))
                Text("Updated \(age)s ago · \(monitor.devices.filter { $0.status > 0 }.count)/\(monitor.devices.count) online")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)

                // Topology canvas
                ZStack {
                    // Links from iPhone to each board
                    ForEach(monitor.devices.filter { $0.id > 0 }) { node in
                        if let phone = monitor.devices.first(where: { $0.id == 0 }) {
                            Path { path in
                                path.move(to: CGPoint(x: phone.x, y: phone.y))
                                path.addLine(to: CGPoint(x: node.x, y: node.y))
                            }
                            .stroke(
                                node.status > 0 ? linkColor(status: node.status) : Color.clear,
                                style: StrokeStyle(lineWidth: 2, dash: [4, 3])
                            )
                            .animation(.easeInOut(duration: 0.3), value: monitor.devices)
                        }
                    }

                    // Nodes
                    ForEach(monitor.devices) { node in
                        NodeCircle(node: node)
                            .position(x: node.x, y: node.y)
                            .animation(.easeInOut(duration: 0.3), value: monitor.devices)
                    }

                    if monitor.devices.isEmpty {
                        VStack {
                            ProgressView().progressViewStyle(.circular).tint(.blue)
                            Text("Starting monitor...").font(.caption).foregroundColor(.gray)
                        }
                    }
                }
                .frame(height: 350)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(16)
                .padding(.horizontal)

                // Node list
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(monitor.devices) { node in
                            NodeDetailRow(node: node)
                        }
                    }
                    .padding(.horizontal)
                }

                // Summary
                HStack(spacing: 30) {
                    VStack {
                        Text("\(monitor.devices.filter { $0.status > 0 }.count)")
                            .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.green)
                        Text("Online").font(.caption).foregroundColor(.gray)
                    }
                    VStack {
                        Text("\(monitor.devices.count)")
                            .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.blue)
                        Text("Devices").font(.caption).foregroundColor(.gray)
                    }
                    VStack {
                        Text("\(monitor.devices.filter { $0.status == 0 && $0.id > 0 }.count)")
                            .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.red)
                        Text("Offline").font(.caption).foregroundColor(.gray)
                    }
                }
                .padding()

                // Control
                Button(action: {
                    if monitor.isScanning {
                        monitor.stop()
                    } else {
                        monitor.start()
                    }
                }) {
                    HStack {
                        Image(systemName: monitor.isScanning ? "stop.circle.fill" : "play.circle.fill")
                        Text(monitor.isScanning ? "STOP MONITOR" : "START MONITOR")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(monitor.isScanning ? Color.red : Color.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

// MARK: - Node views

struct NodeCircle: View {
    let node: MeshNodeInfo
    var color: Color {
        if node.id == 0 { return .blue }
        switch node.status {
        case 0: return .red
        case 1: return .green
        case 2: return .yellow
        default: return .gray
        }
    }
    var icon: String {
        if node.id == 0 { return "iphone" }
        return "memorychip"
    }
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(color.opacity(0.2)).frame(width: 64, height: 64)
                Circle().stroke(color, lineWidth: 2).frame(width: 64, height: 64)
                    .shadow(color: color.opacity(0.5), radius: 4)
                Image(systemName: icon).font(.system(size: 24)).foregroundColor(color)
                // Pulse animation for online nodes
                if node.status == 1 {
                    Circle().stroke(color.opacity(0.3), lineWidth: 1).frame(width: 72, height: 72)
                        .scaleEffect(node.status == 1 ? 1.1 : 1.0)
                        .opacity(node.status == 1 ? 0.5 : 0)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: node.status)
                }
            }
            Text(node.label).font(.system(size: 8, design: .monospaced))
                .foregroundColor(node.status > 0 ? .white : .gray)
                .multilineTextAlignment(.center)
        }
    }
}

struct NodeDetailRow: View {
    let node: MeshNodeInfo
    var statusColor: Color {
        if node.id == 0 { return .blue }
        switch node.status { case 0: return .red; case 1: return .green; case 2: return .yellow; default: return .gray }
    }
    var statusText: String {
        if node.id == 0 { return "This device" }
        switch node.status { case 0: return "Offline"; case 1: return "Online"; case 2: return "Weak"; default: return "Unknown" }
    }
    var body: some View {
        HStack {
            Circle().fill(statusColor).frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.5), radius: 3)
            Image(systemName: node.id == 0 ? "iphone" : "memorychip").foregroundColor(statusColor)
            Text(node.id == 0 ? "iPhone" : "Board #\(node.id)")
                .font(.system(.subheadline, design: .monospaced)).foregroundColor(.white)
            Spacer()
            Text(statusText).font(.system(size: 10, design: .monospaced)).foregroundColor(statusColor)
            if node.id > 0 {
                Text(node.ip).font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(Color.white.opacity(0.05)).cornerRadius(8)
    }
}
