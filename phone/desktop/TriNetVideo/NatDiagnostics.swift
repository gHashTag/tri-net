// NatDiagnostics.swift — the first use of the NAT-traversal stack INSIDE the app. Gather this
// device's ICE candidates (host interface addresses + the STUN server-reflexive address) and
// seal them into a CandidateOffer under the current room key. That sealed blob is exactly what
// a rendezvous will carry to the peer; logging it proves the whole gather -> offer path
// (StunClient + Ice + CandidateOffer) runs in the shipping binary, not just in a harness.
//
// It touches NOTHING in the call / media path — a pure, off-main diagnostic run once at launch.
// Wiring the offer into connection setup (exchange it, then Ice.connect before the media
// socket) is the next step and is deliberately kept separate so it cannot destabilize the
// working same-subnet call.
import Foundation

enum NatDiagnostics {
    static func run() {
        DispatchQueue.global(qos: .utility).async {
            let room = UserDefaults.standard.string(forKey: "trinetRoom") ?? ""
            let hosts = Stun.hostCandidates()
            var cands = hosts.map { Ice.Candidate(ip: $0, port: 0, kind: .host) }
            var srflx = "none"
            if let m = Stun.gatherServerReflexive(host: "stun.l.google.com", port: 19302) {
                cands.append(Ice.Candidate(ip: m.ip, port: m.port, kind: .srflx))
                srflx = "\(m.ip):\(m.port)"
            }
            let offer = CandidateOffer.make(candidates: cands, tiebreaker: UInt64.random(in: 0 ... UInt64.max),
                                            room: room, ttlMs: 60_000)
            NSLog("%@", "TRINET NAT: candidates host=\(hosts) srflx=\(srflx) -> sealed offer \(offer.count)B (room=\(room.isEmpty ? "lobby" : room))")
        }
    }
}
