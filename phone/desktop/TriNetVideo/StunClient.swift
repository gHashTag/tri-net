// StunClient.swift — minimal STUN (RFC 5389) Binding client: the first brick of NAT
// traversal. A serverless call today only connects two devices on the SAME subnet
// because neither side knows its own public address. STUN asks a public server "what
// address did my packet arrive from?", yielding the server-reflexive candidate that a
// later hole-punching step needs to reach a peer across the internet.
//
// This file is pure + standalone (like MeshCrypto / VideoFEC): the XOR-MAPPED-ADDRESS
// unmasking is endian-sensitive and easy to get subtly wrong, so it is proven bit-exact
// against the OFFICIAL RFC 5769 test vectors by smoke/harness/stun_vectors.swift. Not yet
// wired into the transport — that is the next brick (exchange candidates + hole punch).
import Foundation

enum Stun {
    static let magicCookie: UInt32 = 0x2112_A442
    private static let bindingRequestType: UInt16 = 0x0001
    private static let attrXorMappedAddress: UInt16 = 0x0020

    struct MappedAddress: Equatable { let ip: String; let port: UInt16 }

    // A 20-byte Binding Request: type, length 0 (no attributes), magic cookie, 96-bit
    // transaction ID. The caller supplies the transaction ID so a reply can be matched to
    // its request and so the encoder is deterministic under test.
    static func bindingRequest(transactionID: Data) -> Data {
        precondition(transactionID.count == 12, "STUN transaction ID is 96 bits")
        var d = Data(capacity: 20)
        d.append(UInt8(bindingRequestType >> 8)); d.append(UInt8(bindingRequestType & 0xFF))
        d.append(0); d.append(0)                                        // message length = 0
        for shift: UInt32 in [24, 16, 8, 0] { d.append(UInt8((magicCookie >> shift) & 0xFF)) }
        d.append(transactionID)
        return d
    }

    // Parse a Binding success response and return the XOR-MAPPED-ADDRESS it carries. We do
    // NOT verify MESSAGE-INTEGRITY / FINGERPRINT: those authenticate an ICE session, not a
    // plain address query, and a basic candidate gather does not need them. Returns nil on
    // a malformed message or a wrong magic cookie (i.e. not a STUN response).
    static func parseBindingResponse(_ data: Data, transactionID: Data) -> MappedAddress? {
        let b = [UInt8](data)
        guard b.count >= 20 else { return nil }
        let cookie = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        guard cookie == magicCookie else { return nil }
        let msgLen = Int(b[2]) << 8 | Int(b[3])
        guard 20 + msgLen <= b.count else { return nil }
        var i = 20
        while i + 4 <= 20 + msgLen {
            let type = UInt16(b[i]) << 8 | UInt16(b[i + 1])
            let len  = Int(b[i + 2]) << 8 | Int(b[i + 3])
            let valueStart = i + 4
            guard valueStart + len <= b.count else { return nil }
            if type == attrXorMappedAddress {
                return decodeXorMapped(Array(b[valueStart ..< valueStart + len]), transactionID: transactionID)
            }
            i = valueStart + len + ((4 - (len & 3)) & 3)                // attributes are 4-byte aligned
        }
        return nil
    }

    // XOR-MAPPED-ADDRESS value: [reserved 0x00][family][X-Port:2][X-Address:4 or 16].
    //   X-Port    = port XOR (magic cookie >> 16)
    //   X-Address = addr XOR magic cookie              (IPv4)
    //   X-Address = addr XOR (magic cookie || txid)    (IPv6)
    private static func decodeXorMapped(_ v: [UInt8], transactionID: Data) -> MappedAddress? {
        guard v.count >= 8 else { return nil }
        let family = v[1]
        let port = (UInt16(v[2]) << 8 | UInt16(v[3])) ^ UInt16(magicCookie >> 16)
        let cookieBytes: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        if family == 0x01 {                                            // IPv4
            let a = (0..<4).map { v[4 + $0] ^ cookieBytes[$0] }
            return MappedAddress(ip: a.map(String.init).joined(separator: "."), port: port)
        } else if family == 0x02 {                                     // IPv6
            guard v.count >= 20 else { return nil }
            let mask = cookieBytes + [UInt8](transactionID)            // 16-byte XOR mask
            guard mask.count == 16 else { return nil }
            let a = (0..<16).map { v[4 + $0] ^ mask[$0] }
            return MappedAddress(ip: formatIPv6(a), port: port)
        }
        return nil
    }

    // RFC 5952 basic form: each 16-bit group in hex with leading zeros stripped. The one
    // vector we validate (RFC 5769 §2.3) has no zero run to compress, so "::" is not needed.
    private static func formatIPv6(_ a: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2)
            .map { String(UInt16(a[$0]) << 8 | UInt16(a[$0 + 1]), radix: 16) }
            .joined(separator: ":")
    }

    // This machine's non-loopback IPv4 interface addresses — the host candidates.
    static func hostCandidates() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return out }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if ip != "127.0.0.1", !out.contains(ip) { out.append(ip) }
        }
        return out
    }

    // Server-reflexive candidate: send a Binding Request to a public STUN server (host may
    // be a name or an IP) and parse the address it saw. Raw BSD UDP, matching MeshTransport.
    // Best-effort: returns nil if the network blocks it — no server dependency is baked into
    // the hermetic tests, which prove the codec offline against the RFC vectors.
    static func gatherServerReflexive(host: String, port: UInt16, timeoutMs: Int32 = 2000) -> MappedAddress? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: (timeoutMs % 1000) * 1000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let txid = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let req = bindingRequest(transactionID: txid)
        let sent = req.withUnsafeBytes { rp in
            sendto(fd, rp.baseAddress, req.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen)
        }
        guard sent == req.count else { return nil }

        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        return parseBindingResponse(Data(buf.prefix(n)), transactionID: txid)
    }
}
