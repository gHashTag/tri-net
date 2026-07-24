// rendezvous_serverd.swift — a runnable blind rendezvous relay, built from the REAL
// Rendezvous.swift (Mailbox pairing logic + wire codec). It pairs peers by roomHash and hands
// each the OTHER's sealed offer; it never sees the room passphrase and cannot read the offers.
// This is the reference relay a deployment would run (a tiny stateless public host, or the mesh).
// Used by smoke/rendezvous_call.sh to prove the full NAT chain in the app end-to-end.
//   swiftc phone/desktop/TriNetVideo/Rendezvous.swift smoke/rendezvous_serverd.swift -o /tmp/rzd
//   /tmp/rzd 9500
import Foundation

let port = UInt16(CommandLine.arguments.dropFirst().first ?? "9500") ?? 9500
let fd = socket(AF_INET, SOCK_DGRAM, 0)
guard fd >= 0 else { FileHandle.standardError.write(Data("socket() failed\n".utf8)); exit(1) }
var one: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
var me = sockaddr_in()
me.sin_family = sa_family_t(AF_INET)
me.sin_port = port.bigEndian
me.sin_addr.s_addr = 0
let bound = withUnsafePointer(to: &me) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
guard bound == 0 else { FileHandle.standardError.write(Data("bind(:\(port)) failed\n".utf8)); exit(1) }
FileHandle.standardError.write(Data("rendezvous_serverd listening on :\(port)\n".utf8))

var mailbox = Rendezvous.Mailbox()
var buf = [UInt8](repeating: 0, count: 2048)
while true {
    var from = sockaddr_in()
    var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let n = withUnsafeMutablePointer(to: &from) { fp in
        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &flen) }
    }
    guard n > 0 else { continue }
    let pkt = Data(buf.prefix(n))
    if let p = Rendezvous.parsePublish(pkt) {
        mailbox.publish(p)
    } else if let g = Rendezvous.parseGet(pkt) {
        let resp = mailbox.peerOffer(g).map { Rendezvous.encodeOffer($0) } ?? Rendezvous.encodeNone
        _ = resp.withUnsafeBytes { rp in
            withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, rp.baseAddress, resp.count, 0, $0, flen) }
            }
        }
    }
}
