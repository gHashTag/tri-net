// LinkStatus.swift — honest reporting of (a) what the call is actually flowing
// over and (b) the app's own log, live.
//
// Why this exists: the UI said "Encrypted mesh" while every byte went over plain
// Wi-Fi UDP, and the only telemetry (NSLog) was invisible unless the binary was
// launched from a terminal. Both are fixed here: the path is measured, not
// branded, and stderr is teed into the UI.
import Foundation
import Combine
import Darwin

// MARK: - Live log

// Captures the process's own stderr (where NSLog lands) via dup2 into a pipe and
// republishes each line. This picks up every existing NSLog call site untouched.
final class LogBus: ObservableObject {
    static let shared = LogBus()
    @Published private(set) var lines: [String] = []
    private let cap = 400
    private var pipeRead: Int32 = -1
    private var origStderr: Int32 = -1
    private let q = DispatchQueue(label: "trinet.logbus")
    private var started = false

    // Keep writing to the real stderr too, so a terminal launch still shows logs.
    func start() {
        guard !started else { return }
        started = true
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        pipeRead = fds[0]
        origStderr = dup(STDERR_FILENO)
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])
        setvbuf(stderr, nil, _IOLBF, 0)
        q.async { [weak self] in self?.readLoop() }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        var pending = ""
        while true {
            let n = read(pipeRead, &buf, buf.count)
            guard n > 0 else { break }
            if origStderr >= 0 { _ = write(origStderr, buf, n) }   // tee to real stderr
            pending += String(decoding: buf[0..<n], as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[pending.startIndex..<nl])
                pending = String(pending[pending.index(after: nl)...])
                publish(line)
            }
        }
    }

    private func publish(_ raw: String) {
        // Strip the "2026-07-17 08:54:06.986 TriNetMonitor[3058:36669009] " prefix.
        var s = raw
        if let r = s.range(of: "] "), s.hasPrefix("20") { s = String(s[r.upperBound...]) }
        guard !s.isEmpty else { return }
        DispatchQueue.main.async {
            self.lines.append(s)
            if self.lines.count > self.cap { self.lines.removeFirst(self.lines.count - self.cap) }
        }
    }
}

// MARK: - Path

// What the traffic is REALLY going over. Measured from the routing table, never
// assumed — a green "MESH" badge over a Wi-Fi socket is exactly the lie this
// screen exists to prevent.
enum LinkPath: Equatable {
    case wifi(String)        // interface name
    case wired(String)
    case mesh(String)        // radio, only when a mesh route genuinely carries it
    case loopback
    case unknown

    var label: String {
        switch self {
        case .wifi:     return "WI-FI"
        case .wired:    return "ETHERNET"
        case .mesh:     return "MESH"
        case .loopback: return "LOOPBACK"
        case .unknown:  return "NO ROUTE"
        }
    }
    var detail: String {
        switch self {
        case .wifi(let i), .wired(let i), .mesh(let i): return i
        case .loopback: return "lo0"
        case .unknown:  return "-"
        }
    }
    // Only a real radio path may claim the mesh.
    var isMesh: Bool { if case .mesh = self { return true }; return false }
}

final class LinkStatus: ObservableObject {
    @Published private(set) var path: LinkPath = .unknown
    @Published private(set) var peer: String = ""
    // Honest reason the mesh is not carrying traffic, shown next to the badge.
    @Published private(set) var meshNote: String = "radio mesh not attached"

    private var timer: Timer?

    func begin(peer: String) {
        self.peer = peer
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func end() { timer?.invalidate(); timer = nil }

    // Resolve the outbound interface for the peer, then classify it.
    private func refresh() {
        guard !peer.isEmpty else { return }
        let iface = Self.interface(toward: peer)
        let p: LinkPath
        switch iface {
        case "": p = .unknown
        case "lo0": p = .loopback
        default:
            if Self.isWiFi(iface) { p = .wifi(iface) }
            else if iface.hasPrefix("tun") || iface.hasPrefix("utun") { p = .mesh(iface) }
            else { p = .wired(iface) }
        }
        if p != path { DispatchQueue.main.async { self.path = p } }
    }

    // `route get` is the source of truth for which interface a datagram leaves by.
    static func interface(toward host: String) -> String {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/sbin/route")
        t.arguments = ["-n", "get", host]
        let pipe = Pipe()
        t.standardOutput = pipe
        t.standardError = Pipe()
        guard (try? t.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        t.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        for line in out.split(separator: "\n") {
            let f = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if f.count == 2, f[0] == "interface" { return f[1] }
        }
        return ""
    }

    private static func isWiFi(_ iface: String) -> Bool {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        t.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        t.standardOutput = pipe
        t.standardError = Pipe()
        guard (try? t.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        t.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        // "Hardware Port: Wi-Fi\nDevice: en0"
        var lastPortWasWiFi = false
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") { lastPortWasWiFi = line.contains("Wi-Fi") }
            if line.hasPrefix("Device:"), lastPortWasWiFi,
               line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces) == iface {
                return true
            }
        }
        return false
    }
}
