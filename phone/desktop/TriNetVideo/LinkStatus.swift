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
import CoreWLAN
import AppKit

// MARK: - Live log

// Captures the process's own stderr (where NSLog lands) via dup2 into a pipe and
// republishes each line. This picks up every existing NSLog call site untouched.
final class LogBus: ObservableObject {
    static let shared = LogBus()
    @Published private(set) var lines: [String] = []
    // Deep enough to hold a whole call: the pane is read by an agent after the
    // fact, and a call that logs every 500th packet still outruns a short buffer.
    private let cap = 4000
    private var pipeRead: Int32 = -1
    private var origStderr: Int32 = -1
    private let q = DispatchQueue(label: "trinet.logbus")
    private var started = false

    // Persistent log FILE, so the detailed log survives quitting (the in-memory `lines` does not).
    // Standard macOS location -> visible in Console.app and Finder.
    let logURL: URL = {
        // TRINET_LOG lets a second instance write its own log — needed by the two-endpoint
        // test rig so each process's counters can be read independently (never set in a real run).
        if let p = ProcessInfo.processInfo.environment["TRINET_LOG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TriNetMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("monitor.log")
    }()
    var logPath: String { logURL.path }
    private var logFH: FileHandle?
    private let tsFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
    private func appendFile(_ s: String) {
        guard let fh = logFH else { return }
        if let d = "\(tsFmt.string(from: Date())) \(s)\n".data(using: .utf8) { try? fh.write(contentsOf: d) }
    }

    // Keep writing to the real stderr too, so a terminal launch still shows logs.
    func start() {
        guard !started else { return }
        started = true
        // open the persistent log file (append)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        logFH = try? FileHandle(forWritingTo: logURL)
        try? logFH?.seekToEnd()
        appendFile("=== TRI-NET Monitor session start === log: \(logURL.path)")
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
        // Accumulate BYTES, not decoded strings: a 4096-byte read can split a
        // multi-byte UTF-8 character across chunks, and decoding each chunk
        // separately turns that character into U+FFFD forever. Decode only whole
        // lines, once their bytes are all here.
        var pending = Data()
        while true {
            let n = read(pipeRead, &buf, buf.count)
            guard n > 0 else { break }
            if origStderr >= 0 { _ = write(origStderr, buf, n) }   // tee to real stderr
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending = pending[pending.index(after: nl)...]
                publish(line)
            }
        }
    }

    // The full buffer as one pasteable block, headed by the facts a reader would
    // otherwise have to ask for. Every wrong turn in this project started with a
    // log whose build, codec or link was assumed rather than stated.
    func transcript() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let head = """
        === TRI-NET Monitor log ===
        app: \(v) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        opus send: \(AudioController.opusEnabled)   mesh NAL ceiling: \(VideoEncoder.meshMaxNAL)B
        lines: \(lines.count) (buffer holds \(cap))
        ===========================
        """
        return head + "\n" + lines.joined(separator: "\n")
    }

    private func publish(_ raw: String) {
        // Strip the "2026-07-17 08:54:06.986 TriNetMonitor[3058:36669009] " prefix.
        var s = raw
        if let r = s.range(of: "] "), s.hasPrefix("20") { s = String(s[r.upperBound...]) }
        guard !s.isEmpty else { return }
        appendFile(s)                                  // persist every line to the log FILE
        DispatchQueue.main.async {
            self.lines.append(s)
            if self.lines.count > self.cap { self.lines.removeFirst(self.lines.count - self.cap) }
        }
    }

    // Reveal the persistent log file in Finder (also dumps the current in-memory transcript to it first).
    func revealLog() {
        appendFile("--- transcript snapshot ---")
        for l in lines { appendFile(l) }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
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
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
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

    // Which interface would carry a datagram to `host`: the one whose subnet
    // contains it (that IS the route for a peer on the local network).
    //
    // Resolved with getifaddrs, NOT by shelling out to `route`. Spawning `route`
    // every few seconds printed "arp: writing to routing socket: Operation not
    // permitted" into our own stderr, and since LogBus tees stderr into the Log
    // pane, the 400-line buffer filled with that noise and evicted every real
    // diagnostic. The observability tool became the thing it was built to fix.
    static func interface(toward host: String) -> String {
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return "" }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "" }
        defer { freeifaddrs(head) }

        var loopback = ""
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let nm = cur.pointee.ifa_netmask else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if (addr & mask) == (target.s_addr & mask) {
                if flags & IFF_LOOPBACK != 0 { loopback = name; continue }
                return name
            }
        }
        return loopback   // only claim loopback if nothing real matched
    }

    // Wi-Fi is asked of CoreWLAN directly — again, no subprocess.
    private static func isWiFi(_ iface: String) -> Bool {
        CWWiFiClient.shared().interface(withName: iface) != nil
    }
}
