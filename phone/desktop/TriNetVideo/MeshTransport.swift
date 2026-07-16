// MeshTransport.swift — NWConnection-based UDP transport (works on macOS)
import Foundation
import Network

class MeshTransport {
    private var conn: NWConnection?
    private var listener: NWListener?
    var onReceive: ((Data) -> Void)?
    var connected = false

    func connect(peerHost: String, peerPort: UInt16, listenPort: UInt16) {
        disconnect()

        // Send connection
        conn = NWConnection(host: NWEndpoint.Host(peerHost),
                            port: NWEndpoint.Port(rawValue: peerPort)!,
                            using: .udp)
        conn?.start(queue: .global())

        // Listen for incoming
        do {
            listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: listenPort)!)
        } catch { return }
        listener?.newConnectionHandler = { [weak self] c in
            c.start(queue: .global())
            self?.recvLoop(c)
        }
        listener?.start(queue: .global())
        connected = true
    }

    private func recvLoop(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, _ in
            if let d = data { self?.onReceive?(d) }
            self?.recvLoop(c)
        }
    }

    func send(_ data: Data) {
        conn?.send(content: data, completion: .contentProcessed({ _ in }))
    }

    func disconnect() {
        conn?.cancel(); listener?.cancel()
        conn = nil; listener = nil
        connected = false
    }

    static func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr!.pointee.ifa_next }
                let iface = ptr!.pointee
                if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: iface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                        let s = String(cString: host)
                        if !s.hasPrefix("169.254") { address = s }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
