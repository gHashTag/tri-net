// Rendezvous.swift — the meeting point that lets two peers who share ONLY a room passphrase
// find each other's sealed candidate offers (CandidateOffer, #45). Even a serverless P2P call
// needs one for the first exchange: WebRTC uses a signaling server, BitTorrent a tracker/DHT;
// the tri-net vision uses the MESH itself. The rendezvous is a BLIND relay — it is addressed by
// roomHash = SHA256(room passphrase), so it never sees the passphrase, and the offers it stores
// are sealed, so it cannot read or forge candidates. It only pairs "someone else who hashed the
// same room" with "you".
//
// This file is the CLIENT (what the app runs): derive the room hash, publish your sealed offer,
// fetch the peer's. The reference server is a ~15-line UDP loop over the pure mailbox logic below
// (deployed on a tiny public host, or carried by the mesh); smoke/harness/rendezvous.swift runs
// it and proves the whole chain gather -> seal -> publish -> fetch -> open -> Ice.connect over
// loopback. Pure; reuses CryptoKit only for the hash.
import Foundation
import CryptoKit

enum Rendezvous {
    // Public rendezvous key: the relay is addressed by this, never by the passphrase itself.
    static func roomHash(_ room: String) -> Data {
        Data(SHA256.hash(data: Data(room.utf8)).prefix(16))
    }

    // ---- wire codec ----
    // PUBLISH [0x01][selfTag:8 BE][roomHash:16][offer]   store (tag, offer) under roomHash
    // GET     [0x02][selfTag:8 BE][roomHash:16]          fetch an offer whose tag != selfTag
    // OFFER   [0x03][offer]                              response: the peer's sealed offer
    // NONE    [0x04]                                     response: no peer has published yet
    static func encodePublish(selfTag: UInt64, roomHash: Data, offer: Data) -> Data {
        Data([0x01] + be(selfTag)) + roomHash + offer
    }
    static func encodeGet(selfTag: UInt64, roomHash: Data) -> Data {
        Data([0x02] + be(selfTag)) + roomHash
    }
    static func encodeOffer(_ offer: Data) -> Data { Data([0x03]) + offer }
    static let encodeNone = Data([0x04])

    struct Publish: Equatable { let selfTag: UInt64; let roomHash: Data; let offer: Data }
    struct Get: Equatable { let selfTag: UInt64; let roomHash: Data }

    static func parsePublish(_ d: Data) -> Publish? {
        let b = [UInt8](d)
        guard b.count >= 25, b[0] == 0x01 else { return nil }
        return Publish(selfTag: u64(b[1..<9]), roomHash: Data(b[9..<25]), offer: Data(b[25...]))
    }
    static func parseGet(_ d: Data) -> Get? {
        let b = [UInt8](d)
        guard b.count == 25, b[0] == 0x02 else { return nil }
        return Get(selfTag: u64(b[1..<9]), roomHash: Data(b[9..<25]))
    }
    // Returns the peer offer bytes for an OFFER response, or nil for NONE / anything malformed.
    static func parseResponse(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard let first = b.first else { return nil }
        return first == 0x03 ? Data(b[1...]) : nil
    }

    // ---- pure mailbox: the reference rendezvous-server brain (store + pair) ----
    // A relay keeps this; the client never does. Kept here so it is production-tested, not just
    // a harness fixture. Same-room peers land in the same bucket; a GET returns the OTHER tag's
    // offer, so the two sides swap without the relay reading anything.
    struct Mailbox {
        private var buckets: [Data: [(tag: UInt64, offer: Data)]] = [:]
        mutating func publish(_ p: Publish) {
            var list = buckets[p.roomHash, default: []]
            list.removeAll { $0.tag == p.selfTag }          // refresh, don't duplicate, my own slot
            list.append((p.selfTag, p.offer))
            buckets[p.roomHash] = list
        }
        func peerOffer(_ g: Get) -> Data? {
            buckets[g.roomHash]?.first { $0.tag != g.selfTag }?.offer
        }
    }

    // ---- client I/O (raw BSD UDP, matching MeshTransport) ----
    // Publish is best-effort fire-and-forget (retransmitted by the caller loop if needed).
    static func publish(roomHash: Data, selfTag: UInt64, offer: Data, host: String, port: UInt16) {
        sendOne(encodePublish(selfTag: selfTag, roomHash: roomHash, offer: offer), host: host, port: port)
    }
    // Poll GET until the peer's offer appears or the deadline passes.
    static func fetch(roomHash: Data, selfTag: UInt64, host: String, port: UInt16, timeoutMs: Int = 4000) -> Data? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var srv = addr(host, port)
        let req = encodeGet(selfTag: selfTag, roomHash: roomHash)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            _ = req.withUnsafeBytes { rp in
                withUnsafePointer(to: &srv) { sp in
                    sp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, rp.baseAddress, req.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0, let offer = parseResponse(Data(buf.prefix(n))) { return offer }
        }
        return nil
    }

    private static func sendOne(_ data: Data, host: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var srv = addr(host, port)
        _ = data.withUnsafeBytes { dp in
            withUnsafePointer(to: &srv) { sp in
                sp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, dp.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    private static func addr(_ host: String, _ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &a.sin_addr)
        return a
    }
    private static func be(_ x: UInt64) -> [UInt8] { (0..<8).map { UInt8((x >> (56 - 8 * $0)) & 0xFF) } }
    private static func u64(_ s: ArraySlice<UInt8>) -> UInt64 { s.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
}
