// Verifies the STUN codec in the ACTUAL StunClient.swift against the OFFICIAL RFC 5769
// test vectors. The XOR-MAPPED-ADDRESS unmasking is the fiddly, endian-sensitive part, and
// these are the IETF's own reference bytes, so a green run means bit-exact agreement with
// every conformant STUN server. Pure + offline (no socket) — safe inside verify.sh.
//   swiftc StunClient.swift stun_vectors.swift -o /tmp/stun && /tmp/stun
import Foundation

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

// RFC 5769 §2.1/§2.2/§2.3 all share this 96-bit transaction ID.
let txid = Data([0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae])

print("== encoder: a Binding Request header is exactly type/len/cookie/txid ==")
do {
    let req = Stun.bindingRequest(transactionID: txid)
    let expected = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xa4, 0x42] + [UInt8](txid))
    check(req == expected, "Binding Request is 20 bytes: type=0x0001, len=0, magic cookie, txid")
}

print("== RFC 5769 2.2: IPv4 XOR-MAPPED-ADDRESS decodes to 192.0.2.1:32853 ==")
do {
    // header (success response 0x0101, msg-len = the 12-byte attribute) + the RFC's exact
    // XOR-MAPPED-ADDRESS bytes. IPv4 X-Address XORs only the magic cookie, so this unmask is
    // independent of the transaction ID.
    let attr: [UInt8] = [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43]
    let msg = Data([0x01, 0x01, 0x00, 0x0c, 0x21, 0x12, 0xa4, 0x42] + [UInt8](txid) + attr)
    let m = Stun.parseBindingResponse(msg, transactionID: txid)
    check(m?.ip == "192.0.2.1", "X-Address unmasks to 192.0.2.1")
    check(m?.port == 32853, "X-Port unmasks to 32853")
}

print("== RFC 5769 2.3: IPv6 XOR-MAPPED-ADDRESS decodes to the RFC address:32853 ==")
do {
    // IPv6 X-Address XORs the magic cookie CONCATENATED WITH the transaction ID, so the
    // official txid above is load-bearing here (unlike IPv4).
    let attr: [UInt8] = [0x00, 0x20, 0x00, 0x14, 0x00, 0x02, 0xa1, 0x47,
                         0x01, 0x13, 0xa9, 0xfa, 0xa5, 0xd3, 0xf1, 0x79,
                         0xbc, 0x25, 0xf4, 0xb5, 0xbe, 0xd2, 0xb9, 0xd9]
    let msg = Data([0x01, 0x01, 0x00, 0x18, 0x21, 0x12, 0xa4, 0x42] + [UInt8](txid) + attr)
    let m = Stun.parseBindingResponse(msg, transactionID: txid)
    check(m?.ip == "2001:db8:1234:5678:11:2233:4455:6677", "X-Address unmasks to the RFC 5769 IPv6 address")
    check(m?.port == 32853, "X-Port unmasks to 32853")
}

print("== robustness: non-STUN and truncated inputs are rejected, never crash ==")
do {
    let attr: [UInt8] = [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43]
    let badCookie = Data([0x01, 0x01, 0x00, 0x0c, 0xde, 0xad, 0xbe, 0xef] + [UInt8](txid) + attr)
    check(Stun.parseBindingResponse(badCookie, transactionID: txid) == nil, "wrong magic cookie -> nil (not a STUN response)")
    check(Stun.parseBindingResponse(Data([0x01, 0x01, 0x00, 0x00]), transactionID: txid) == nil, "too-short message -> nil, no crash")
    // an attribute whose declared length runs past the buffer must not read out of bounds
    // (msg-len = 4 admits the 4-byte attribute header into the loop; its value-len is 0xffff)
    let overrun = Data([0x01, 0x01, 0x00, 0x04, 0x21, 0x12, 0xa4, 0x42] + [UInt8](txid) + [0x00, 0x20, 0xff, 0xff])
    check(Stun.parseBindingResponse(overrun, transactionID: txid) == nil, "attribute length past end -> nil, no crash")
}

print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
exit(fails == 0 ? 0 : 1)
