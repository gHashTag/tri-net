// PeerDiscovery.swift — TRI-NET local-network presence, so you pick people by NAME instead of typing IPs.
// Bonjour via Network.framework: publish `_trinet._udp` (NWListener, advertiser only — our real encrypted
// UDP transport keeps port 7000), browse for peers (NWBrowser + TXT), and resolve the ONE peer you tap to
// an IP via a throwaway NWConnection. Keyed on a stable per-install UID so the same person survives IP
// changes. Extras: ROOM codes (only see/join peers in your room) and STATUS (idle / in-call) in the TXT.
import Foundation
import Network
#if os(iOS)
import UIKit
#endif

final class PeerDiscovery: ObservableObject {
    struct Peer: Identifiable, Equatable {
        let uid: String
        var name: String
        var room: String
        var status: String          // "idle" | "call"
        let endpoint: NWEndpoint
        var id: String { uid }
        static func == (a: Peer, b: Peer) -> Bool {
            a.uid == b.uid && a.name == b.name && a.status == b.status && a.room == b.room
        }
    }

    @Published var peers: [Peer] = []          // live roster (self excluded, filtered by room)
    static let serviceType = "_trinet._udp"
    static let transportPort = 7000            // our real UDP transport; discovery only yields the IP

    // Stable identity: a UUID generated once and persisted, so "same person, new IP" is recognized.
    static let myUID: String = {
        let k = "trinetPeerUID"
        if let s = UserDefaults.standard.string(forKey: k) { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: k)
        return s
    }()

    // User-chosen display name (entitlement-free replacement for UIDevice.name, generic on iOS 16+).
    static var myName: String {
        get {
            if let n = UserDefaults.standard.string(forKey: "trinetDisplayName"), !n.isEmpty { return n }
            #if os(iOS)
            return UIDevice.current.name
            #else
            return Host.current().localizedName ?? "Mac"
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: "trinetDisplayName") }
    }
    // Room code: empty => the open lobby (see everyone); set => only peers in the SAME room (auto-join UX).
    static var myRoom: String {
        get { UserDefaults.standard.string(forKey: "trinetRoom") ?? "" }
        set { UserDefaults.standard.set(newValue.uppercased(), forKey: "trinetRoom") }
    }

    @Published var inCall = false { didSet { if oldValue != inCall { republish() } } }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var started = false

    func start() { started = true; publish(); browse() }
    func stop() {
        started = false
        listener?.cancel(); browser?.cancel()
        listener = nil; browser = nil
        DispatchQueue.main.async { self.peers = [] }
    }

    // Change our advertised name or room, then re-advertise so peers see it immediately.
    func setName(_ name: String) { PeerDiscovery.myName = name; republish() }
    func setRoom(_ room: String) { PeerDiscovery.myRoom = room; republish() }

    private func republish() {
        guard started else { return }
        listener?.cancel(); listener = nil
        publish()
        DispatchQueue.main.async { self.peers = [] }   // room may have changed -> re-filter from scratch
    }

    // Advertise ourselves. NWListener is a PURE advertiser (binds a throwaway port); we never accept its
    // connections. name/uid/port/room/status travel in the TXT record.
    private func publish() {
        var txt = NWTXTRecord()
        txt["name"] = PeerDiscovery.myName
        txt["uid"] = PeerDiscovery.myUID
        txt["port"] = "\(PeerDiscovery.transportPort)"
        txt["room"] = PeerDiscovery.myRoom
        txt["status"] = inCall ? "call" : "idle"
        do {
            let l = try NWListener(using: .udp)
            l.service = NWListener.Service(name: PeerDiscovery.myName + "\u{00A0}" + String(PeerDiscovery.myUID.prefix(4)),
                                           type: PeerDiscovery.serviceType, domain: "local.", txtRecord: txt)
            l.newConnectionHandler = { $0.cancel() }
            l.stateUpdateHandler = { st in if case .failed(let e) = st { NSLog("TRINET: discovery publish failed: \(e)") } }
            l.start(queue: .main)
            listener = l
            NSLog("TRINET: discovery advertising '\(PeerDiscovery.myName)' room='\(PeerDiscovery.myRoom)' status=\(inCall ? "call" : "idle")")
        } catch { NSLog("TRINET: discovery NWListener failed: \(error)") }
    }

    // Live roster from the TXT-aware browser; self filtered by uid, and by ROOM if one is set.
    private func browse() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: PeerDiscovery.serviceType, domain: "local."), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            let room = PeerDiscovery.myRoom
            var list: [Peer] = []
            for r in results {
                guard case let .bonjour(txt) = r.metadata else { continue }
                let uid = txt["uid"] ?? ""
                if uid.isEmpty || uid == PeerDiscovery.myUID { continue }
                let peerRoom = txt["room"] ?? ""
                if !room.isEmpty && peerRoom != room { continue }   // room filter: only my room
                if list.contains(where: { $0.uid == uid }) { continue }
                list.append(Peer(uid: uid, name: txt["name"] ?? "TRI-NET", room: peerRoom,
                                 status: txt["status"] ?? "idle", endpoint: r.endpoint))
            }
            let sorted = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
            DispatchQueue.main.async {
                self.peers = sorted
                NSLog("TRINET: roster \(sorted.count) peer(s): \(sorted.map { $0.name }.joined(separator: ", "))")
            }
        }
        b.stateUpdateHandler = { st in if case .failed(let e) = st { NSLog("TRINET: discovery browse failed: \(e)") } }
        b.start(queue: .main)
        browser = b
        NSLog("TRINET: discovery browsing \(PeerDiscovery.serviceType)")
    }

    // Resolve ONE tapped peer's Bonjour endpoint to an IP via a short-lived NWConnection (Apple: never
    // resolve the whole roster). We ignore the resolved port and use transportPort.
    func resolveIP(_ peer: Peer, completion: @escaping (String?) -> Void) {
        // Force IPv4: our UDP transport is sockaddr_in / inet_addr only. Bonjour otherwise resolves to an
        // IPv6 link-local (fe80::…) first, which inet_addr can't parse — so packets go nowhere. Ask the
        // NWConnection for IPv4 and never hand back a v6 address.
        let params = NWParameters.udp
        if let ipOpt = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpt.version = .v4
        }
        let conn = NWConnection(to: peer.endpoint, using: params)
        var done = false
        let finish: (String?) -> Void = { ip in
            if done { return }; done = true
            NSLog("TRINET: resolved '\(peer.name)' -> \(ip ?? "FAILED")")
            conn.cancel(); DispatchQueue.main.async { completion(ip) }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var ip: String?
                if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
                    switch host {
                    case .ipv4(let a): ip = "\(a)".components(separatedBy: "%").first
                    case .ipv6: ip = nil   // IPv4-only transport — never use a v6 address
                    case .name(let n, _): ip = n
                    @unknown default: break
                    }
                }
                finish(ip)
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }   // never hang the UI
    }
}
