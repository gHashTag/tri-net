// Verifies the rendezvous in the ACTUAL Rendezvous.swift (+ CandidateOffer + Ice + HolePunch +
// MeshCrypto). Two layers: (1) pure, deterministic — wire codec, room-hash blinding, and the
// mailbox pairing logic; (2) a LIVE end-to-end chain — a reference UDP rendezvous server plus
// two clients that gather -> seal -> publish -> fetch -> open -> Ice.connect and actually connect
// over loopback, knowing only a shared room passphrase. The live layer is robust (retransmit +
// poll on lossless loopback), not lucky.
//   swiftc MeshCrypto.swift HolePunch.swift IceSession.swift CandidateOffer.swift Rendezvous.swift rendezvous.swift -o /tmp/rz && /tmp/rz
import Foundation
import CryptoKit

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

print("== room hash blinds the passphrase ==")
do {
    let h1 = Rendezvous.roomHash("team-alpha")
    let h2 = Rendezvous.roomHash("team-alpha")
    let h3 = Rendezvous.roomHash("team-beta")
    check(h1 == h2 && h1.count == 16, "same room -> same 16-byte hash")
    check(h1 != h3, "different rooms -> different hashes (relay cannot correlate)")
    check(h1.contains(where: { $0 != 0 }), "hash is not all-zero (sanity)")
}

print("== wire codec round-trips ==")
do {
    let rh = Rendezvous.roomHash("r"); let offer = Data([9, 8, 7, 6, 5])
    let pub = Rendezvous.parsePublish(Rendezvous.encodePublish(selfTag: 0xABCD, roomHash: rh, offer: offer))
    check(pub == Rendezvous.Publish(selfTag: 0xABCD, roomHash: rh, offer: offer), "PUBLISH round-trips")
    let get = Rendezvous.parseGet(Rendezvous.encodeGet(selfTag: 0x1234, roomHash: rh))
    check(get == Rendezvous.Get(selfTag: 0x1234, roomHash: rh), "GET round-trips")
    check(Rendezvous.parseResponse(Rendezvous.encodeOffer(offer)) == offer, "OFFER response yields the offer")
    check(Rendezvous.parseResponse(Rendezvous.encodeNone) == nil, "NONE response yields nil")
    check(Rendezvous.parsePublish(Data([0x02, 1, 2])) == nil, "a GET is not a PUBLISH; short input -> nil")
}

print("== mailbox pairs same-room peers and returns the OTHER one ==")
do {
    var mb = Rendezvous.Mailbox()
    let rh = Rendezvous.roomHash("team")
    mb.publish(.init(selfTag: 1, roomHash: rh, offer: Data([0xAA])))
    mb.publish(.init(selfTag: 2, roomHash: rh, offer: Data([0xBB])))
    check(mb.peerOffer(.init(selfTag: 1, roomHash: rh)) == Data([0xBB]), "peer of tag 1 is tag 2's offer")
    check(mb.peerOffer(.init(selfTag: 2, roomHash: rh)) == Data([0xAA]), "peer of tag 2 is tag 1's offer")
    check(mb.peerOffer(.init(selfTag: 9, roomHash: Rendezvous.roomHash("other"))) == nil, "unknown room -> nil")
    mb.publish(.init(selfTag: 1, roomHash: rh, offer: Data([0xCC])))          // refresh my own slot
    check(mb.peerOffer(.init(selfTag: 2, roomHash: rh)) == Data([0xCC]), "re-publish refreshes, does not duplicate")
}

print("== LIVE chain: two peers who share only a room passphrase connect via the rendezvous ==")
do {
    final class Flag { let lk = NSLock(); private var r = true
        var run: Bool { lk.lock(); defer { lk.unlock() }; return r }
        func stop() { lk.lock(); r = false; lk.unlock() } }

    func runServer(port: UInt16, flag: Flag) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return }
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var me = sockaddr_in(); me.sin_family = sa_family_t(AF_INET); me.sin_port = port.bigEndian; me.sin_addr.s_addr = 0
        _ = withUnsafePointer(to: &me) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var tv = timeval(tv_sec: 0, tv_usec: 100_000); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var mailbox = Rendezvous.Mailbox()
        var buf = [UInt8](repeating: 0, count: 2048)
        while flag.run {
            var from = sockaddr_in(); var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &flen) } }
            guard n > 0 else { continue }
            let pkt = Data(buf.prefix(n))
            if let p = Rendezvous.parsePublish(pkt) { mailbox.publish(p) }
            else if let g = Rendezvous.parseGet(pkt) {
                let resp = mailbox.peerOffer(g).map { Rendezvous.encodeOffer($0) } ?? Rendezvous.encodeNone
                _ = resp.withUnsafeBytes { rp in withUnsafeMutablePointer(to: &from) { fp in fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, rp.baseAddress, resp.count, 0, $0, flen) } } }
            }
        }
        close(fd)
    }

    func peer(room: String, selfTag: UInt64, mediaPort: UInt16, serverPort: UInt16) -> Ice.Connected? {
        let rh = Rendezvous.roomHash(room)
        let mine = [Ice.Candidate(ip: "127.0.0.1", port: mediaPort, kind: .host)]
        let offer = CandidateOffer.make(candidates: mine, tiebreaker: selfTag, room: room, ttlMs: 30_000)
        for _ in 0..<3 { Rendezvous.publish(roomHash: rh, selfTag: selfTag, offer: offer, host: "127.0.0.1", port: serverPort) }
        guard let peerOffer = Rendezvous.fetch(roomHash: rh, selfTag: selfTag, host: "127.0.0.1", port: serverPort, timeoutMs: 4000),
              let opened = CandidateOffer.open(peerOffer, room: room) else { return nil }
        return Ice.connect(localPort: mediaPort, remote: opened.candidates, timeoutMs: 2500)
    }

    let flag = Flag()
    DispatchQueue.global().async { runServer(port: 48500, flag: flag) }
    var rA: Ice.Connected?, rB: Ice.Connected?
    let g = DispatchGroup()
    g.enter(); DispatchQueue.global().async { rA = peer(room: "secret-room", selfTag: 0xA, mediaPort: 48411, serverPort: 48500); g.leave() }
    g.enter(); DispatchQueue.global().async { rB = peer(room: "secret-room", selfTag: 0xB, mediaPort: 48412, serverPort: 48500); g.leave() }
    g.wait(); flag.stop()

    check(rA?.remote.port == 48412, "A found + connected to B (127.0.0.1:48412) knowing only the room name")
    check(rB?.remote.port == 48411, "B found + connected to A (127.0.0.1:48411) knowing only the room name")
    check(rA?.localPort == 48411 && rB?.localPort == 48412, "each reports its own media port for the call")
}

print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
exit(fails == 0 ? 0 : 1)
