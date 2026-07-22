// MeshTransport.swift — BSD-socket UDP transport.
// NWListener on macOS binds IPv6-only and silently drops IPv4 datagrams
// (proven in VideoCallTab: BSD recvfrom received 770k+ packets where
// NWListener received zero). One AF_INET socket bound to :listenPort
// handles both directions, so the peer sees our source port = 7000.
import Foundation
import Darwin
import CryptoKit

class MeshTransport {
    // DEBUG-only network fault injection (0 = off), read once from env so a loopback call can be driven under
    // real loss with no root privileges. Never set in a shipping build.
    //   TRINET_DROP=<pct>  drops that % of received packets. This is the CORRECT instrument for the loss-based
    //     controller (it honestly lowers the peer's received-frame count); a run PROVED 25% drop -> sustained
    //     residual-loss back-off + a 720->540->360 resolution step-down.
    //   TRINET_JITTER=<ms>  sleeps a random 0..ms on the recv thread. NOTE: this models a SLOW CONSUMER, not
    //     network reordering, and it perturbs the very thread that measures arrival gaps (a broken-ruler
    //     instrument) — do not trust a jitter figure derived from it. The delay-based controller is better
    //     exercised by the closed-loop bandwidth-step harness.
    // Camera frames only flow when the app runs WITH A WINDOW (`open -n --env TRINET_DROP=25 ...`); the bare
    // binary delivers no video, and jitter==0/probe-up then means "no stream", not "clean link".
    private let dropPercent = Int(ProcessInfo.processInfo.environment["TRINET_DROP"] ?? "") ?? 0
    private let jitterMs = Int(ProcessInfo.processInfo.environment["TRINET_JITTER"] ?? "") ?? 0
    private var fd: Int32 = -1
    private var peer = sockaddr_in()          // 1-1 peer (ephemeral session)
    private var peerHostStr = ""              // the connected peer's IP, for drop diagnostics
    private var dropByIP: [String: Int] = [:] // undecryptable datagrams per source IP
    private var peers: [(addr: sockaddr_in, ip: String)] = []  // group peers
    private var running = false
    private let rxQueue = DispatchQueue(label: "mesh.rx", qos: .userInitiated)
    // Separate queue: rxQueue is parked forever in a blocking recv(), so a
    // timer scheduled on it would never fire.
    private let hsQueue = DispatchQueue(label: "mesh.hs", qos: .userInitiated)
    var onReceive: ((Data) -> Void)?
    // Group calls need to know WHO sent each datagram (per-source decoding +
    // roster), so recvfrom carries the sender IP up alongside the payload.
    var onReceiveFrom: ((Data, String) -> Void)?
    var connected = false

    // MARK: link feedback (see specs/video_bridge.t27)
    //
    // The node knows its load exactly; we do not. Without this the encoder finds
    // the link's capacity by overrunning it and waiting for the FAR end's
    // decoder to complain (PLI) — which only happens after frames are already
    // broken. Measured on a live call: 44% of our packets dropped by the node,
    // with nothing telling us.
    //
    // Plaintext by design: local telemetry from our own node, no payload bytes,
    // nothing about content. Never put content here.
    /// (advice, utilPct, dropPct, rate). `advice` is the node's VERDICT and the
    /// only thing to act on — the thresholds live in specs/video_bridge.t27 and
    /// nowhere else, because t27c cannot generate Swift and a second copy here
    /// would drift until the node and the encoder disagreed about "full".
    /// The numbers are for the log and the UI.
    var onLinkFeedback: ((_ advice: UInt8, _ utilPct: Int, _ dropPct: Int, _ rate: Int) -> Void)?
    private var fbFd: Int32 = -1
    // A fresh report proves a NODE is relaying for us; used only to route audio.
    private var lastFeedbackAt: Date?
    private static let audioPort: UInt16 = 7002
    private var expressTx = 0
    private var expressErrs = 0
    private let fbQueue = DispatchQueue(label: "mesh.fb", qos: .utility)
    private static let feedbackPort: UInt16 = 7003
    private static let feedbackType: UInt8 = 10
    private static let feedbackLen = 6

    private func startFeedbackListener() {
        stopFeedbackListener()
        fbFd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fbFd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fbFd, SOL_SOCKET, SO_REUSEADDR, &on, 4)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = MeshTransport.feedbackPort.bigEndian
        addr.sin_addr.s_addr = 0
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Foundation.bind(fbFd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound < 0 {
            // Not fatal: a direct peer-to-peer call has no node to report, so
            // silence here is normal. Say so rather than looking broken.
            NSLog("TRINET: link feedback port busy — running without node telemetry")
            close(fbFd); fbFd = -1
            return
        }
        let fd = fbFd
        fbQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 32)
            while true {
                guard let self = self, self.fbFd == fd else { break }
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                guard n >= MeshTransport.feedbackLen,
                      buf[0] == MeshTransport.feedbackType else { continue }
                let util = Int(buf[1]), drop = Int(buf[2])
                let rate = Int(buf[3]) | (Int(buf[4]) << 8)
                let advice = buf[5]
                self.lastFeedbackAt = Date()
                DispatchQueue.main.async { self.onLinkFeedback?(advice, util, drop, rate) }
            }
        }
    }

    private func stopFeedbackListener() {
        if fbFd >= 0 { close(fbFd); fbFd = -1 }
    }

    // Conference mode: a group of >1 peers shares one static conference key
    // (HKDF of the PSK) instead of pairwise ephemeral handshakes — full-mesh
    // broadcast to 2-4 nodes, the right topology for a zero-server mesh.
    private var groupMode = false
    private var groupKey: SymmetricKey?

    /// Audio goes to the node's express ingress (AUDIO_IN_PORT 7002): its own
    /// budget, never paced, so it cannot queue behind a keyframe -- and it skips
    /// the parity duplicate (a parity over ONE fragment IS a copy; measured,
    /// audio cost 100 frags/s of a 700/s budget on the video port, half of it
    /// duplicates). Same sealing, different door. Only when a node has proven
    /// itself with a fresh report: on a direct call the peer listens on the
    /// main port alone, and this falls back to the normal path.
    func sendAudio(_ data: Data) {
        let viaNode = lastFeedbackAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        if groupMode || !viaNode {
            send(data)
            return
        }
        guard fd >= 0, let wire = crypto.seal(data) else { return }
        var addr = peer
        addr.sin_port = MeshTransport.audioPort.bigEndian
        // Never fail silently in an audio path: a discarded sendto result made
        // vanishing audio indistinguishable from working audio -- the tx
        // counter counts hand-offs, not deliveries.
        let sent = wire.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    sendto(fd, raw.baseAddress, wire.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            expressErrs += 1
            if expressErrs % 100 == 1 {
                NSLog("%@", "TRINET: audio express sendto FAILED: \(String(cString: strerror(errno))) (#\(expressErrs))")
            }
        } else {
            expressTx += 1
            if expressTx == 1 { NSLog("%@", "TRINET: audio express up -> :7002 (\(sent)B)") }
            if expressTx % 2500 == 0 { NSLog("%@", "TRINET: audio express #\(expressTx)") }
        }
    }

    // 1-1 (ephemeral forward-secret) — unchanged path.
    func connect(peerHost: String, peerPort: UInt16, listenPort: UInt16) {
        disconnect()
        groupMode = false
        crypto.room = PeerDiscovery.myRoom   // bind the handshake to the room passphrase
        startFeedbackListener()

        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            NSLog("TRINET: socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, 4)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                Darwin.bind(fd, s, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else {
            NSLog("TRINET: bind(:\(listenPort)) failed: \(String(cString: strerror(errno)))")
            close(fd); fd = -1
            return
        }

        peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = peerPort.bigEndian
        peer.sin_addr.s_addr = inet_addr(peerHost)
        peerHostStr = peerHost
        dropByIP.removeAll()

        running = true
        connected = true
        NSLog("TRINET: BSD transport up — listen :\(listenPort), peer \(peerHost):\(peerPort)")

        // Drive the handshake until a session is established (both sides send
        // periodically so neither has to be "first").
        let timer = DispatchSource.makeTimerSource(queue: hsQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.crypto.established { self.handshakeTimer?.cancel(); self.handshakeTimer = nil; return }
            self.rawSendWire(self.crypto.handshakePacket())
        }
        handshakeTimer = timer
        timer.resume()

        startRx(fd)
    }

    // Receive loop shared by 1-1 and group. recvfrom carries the sender's
    // address so the caller can route by source (per-source decoding + roster).
    private func startRx(_ sock: Int32) {
        rxQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var from = sockaddr_in()
            var count = 0
            while true {
                guard let self = self, self.running else { break }
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                        recvfrom(sock, &buf, buf.count, 0, s, &fromLen)
                    }
                }
                if n > 0 {
                    // DEBUG fault injection: drop a % of received packets (env TRINET_DROP=25) to test the
                    // adaptive loop under real loss without root/dummynet. Random drops also add inter-arrival
                    // jitter, which drives the BWE. No-op in production (default 0).
                    if self.dropPercent > 0, Int.random(in: 0..<100) < self.dropPercent { continue }
                    if self.jitterMs > 0 { usleep(useconds_t(Int.random(in: 0...self.jitterMs) * 1000)) }
                    let pkt = Data(bytes: buf, count: n)
                    let senderIP = String(cString: inet_ntoa(from.sin_addr))
                    if self.groupMode {
                        guard let key = self.groupKey,
                              let box = try? ChaChaPoly.SealedBox(combined: pkt),
                              let plain = try? ChaChaPoly.open(box, using: key),
                              self.crypto.acceptNonce(pkt.prefix(12)) else { continue }   // + anti-replay
                        if let msg = self.reassemble(plain) {
                            self.onReceiveFrom?(msg, senderIP)
                        }
                        continue
                    }
                    // 1-1 ephemeral path
                    if self.crypto.isHandshake(pkt) {
                        self.crypto.consumeHandshake(pkt)
                        self.rawSendWire(self.crypto.handshakePacket())
                        continue
                    }
                    count += 1
                    if count == 1 || count % 500 == 0 { NSLog("TRINET: rx #\(count) \(n)B from \(senderIP)") }
                    if let plain = self.crypto.unseal(pkt) {
                        if let msg = self.reassemble(plain) {
                            self.onReceive?(msg)
                            self.onReceiveFrom?(msg, senderIP)
                        }
                    } else {
                        // Undecryptable: either OUR peer (a real bug — wrong key/corruption) or a STRAY peer
                        // on the shared LAN blasting :7000 (benign). The sender IP tells them apart.
                        self.dropByIP[senderIP, default: 0] += 1
                        let c = self.dropByIP[senderIP]!
                        if c <= 3 || c % 500 == 0 {
                            let who = senderIP == self.peerHostStr ? "OUR PEER — REAL BUG" : "stray peer (ignore)"
                            NSLog("TRINET: DROP undecryptable \(n)B from \(senderIP) [\(who), peer=\(self.peerHostStr)] — \(c) from this IP")
                        }
                    }
                } else if n < 0 {
                    // UDP + ICMP gotcha: a previous sendto to an UNREACHABLE peer delivers its ICMP
                    // error (EHOSTDOWN / ECONNREFUSED / ENETUNREACH / EHOSTUNREACH) on the NEXT recvfrom.
                    // These are TRANSIENT — one dead group peer, or a peer not yet bound during 1-1
                    // startup, must NOT kill the whole receive loop (that ended the entire call ~15s in,
                    // caught by a live loopback test). EINTR is a transient interrupt. Only a genuinely
                    // closed socket (EBADF, when running -> false) exits the loop.
                    let e = errno
                    if e == EINTR || e == EHOSTDOWN || e == ECONNREFUSED || e == ENETUNREACH
                        || e == EHOSTUNREACH || e == EAGAIN || e == EWOULDBLOCK { continue }
                    break
                }
                // n == 0: a zero-length UDP datagram (UDP has no EOF) — ignore and keep receiving.
            }
        }
    }

    // MARK: application-level fragmentation
    // macOS caps a UDP datagram at net.inet.udp.maxdgram (9216B default), so
    // I-frames (10-60KB) can NEVER be sent whole ("Message too long") and the
    // peer sees only P-frames -> decoder stuck at BadDataErr. NALs larger
    // than maxPayload are split into [0xFA 0xFB seqLo seqHi idx total]+chunk
    // datagrams (< WiFi MTU, so no IP fragmentation either) and reassembled
    // on receive. Raw NALs always start 00 00 00 01, so the magic is unambiguous.
    private let maxPayload = 1200
    private var fragSeqOut: UInt16 = 0
    // `tick` orders partial groups by arrival so GC can evict the OLDEST rather
    // than everything but the current seq (see reassemble).
    private var fragBufs: [UInt16: (parts: [Data?], have: Int, tick: UInt64)] = [:]
    private var fragTick: UInt64 = 0
    private let fragBufsCap = 24
    // FEC parity per fragment GROUP: seq -> gStart -> (xor, gLen, lastLen, total).
    private var fecBufs: [UInt16: [Int: (xor: [UInt8], gLen: Int, lastLen: Int, total: Int)]] = [:]
    // Fragments covered by one parity. cleanGroup on a good link; the call shrinks it
    // toward lossyGroup while the far end is dropping frames (more parity where needed).
    var fecGroup = VideoFEC.cleanGroup
    // Send parity only when the peer is known to understand it (see send()).
    // Receiving parity is always safe, so only the send side is gated.
    private let fecEnabled = true
    private var sendErrCount = 0

    // MARK: forward-secret session (see MeshCrypto). Data is sealed under a
    // per-connection ephemeral session key; the static PSK only authenticates
    // the handshake, so a later PSK leak can't decrypt recorded traffic.
    private let crypto = MeshCrypto()
    private var handshakeTimer: DispatchSourceTimer?

    func send(_ data: Data) {
        guard fd >= 0 else { return }
        if data.count <= maxPayload {
            rawSend(data)
            return
        }
        let total = (data.count + maxPayload - 1) / maxPayload
        guard total <= 255 else { return }
        fragSeqOut &+= 1
        var wire = [Data]()
        for i in 0..<total {
            let start = i * maxPayload
            let end = min(start + maxPayload, data.count)
            var pkt = Data([0xFA, 0xFB, UInt8(fragSeqOut & 0xFF), UInt8(fragSeqOut >> 8), UInt8(i), UInt8(total)])
            pkt.append(data.subdata(in: start..<end))
            wire.append(pkt)
            rawSend(pkt)
        }
        // Forward error correction: one XOR-parity packet over all fragments
        // (each cell padded to maxPayload). Lets the peer rebuild ANY single lost
        // fragment without a keyframe request.
        //
        // OFF until BOTH ends run >= v0.9. A pre-v0.9 receiver does NOT ignore an
        // unknown magic: its reassemble() returns any non-0xFA-0xFB datagram as a
        // finished NAL, so parity reached the H.264 decoder as garbage -> decode
        // errors -> PLI -> keyframe storm -> frozen video. There is no safe way to
        // probe an old peer either (any new magic chokes it the same way), so this
        // stays a build-time gate rather than a negotiation.
        if fecEnabled, total >= 2 {
            // One XOR parity per GROUP of fecGroup fragments (adaptive: shrinks under loss).
            // A big keyframe gets several parities instead of one, so a scattered loss no
            // longer sinks the whole frame. Wire adds gStart/gLen naming the covered range.
            let payload = [UInt8](data)
            let lastLen = data.count - (total - 1) * maxPayload
            for gStart in VideoFEC.groupStarts(total: total, group: fecGroup) {
                let gLen = min(fecGroup, total - gStart)
                let xor = VideoFEC.parity(payload, maxPayload: maxPayload, gStart: gStart, gLen: gLen, total: total)
                var parity = Data([0xFA, 0xEC, UInt8(fragSeqOut & 0xFF), UInt8(fragSeqOut >> 8),
                                   UInt8(total), UInt8(gStart), UInt8(gLen), UInt8(lastLen & 0xFF), UInt8(lastLen >> 8)])
                parity.append(contentsOf: xor)
                wire.append(parity)
                rawSend(parity)
            }
        }
        // Buffer this NAL's wire packets so a NACK can re-send them. 1-1 only: group
        // is best-effort. seal() uses a random nonce (MeshCrypto), so re-sealing on
        // resend is safe — no counter to collide across threads.
        if !groupMode { bufferSentNAL(fragSeqOut, wire) }
    }

    // MARK: NACK retransmission (1-1). The ONLY loss recovery that reaches a fully
    // lost single-fragment P-frame: FEC needs >=2 fragments, and the frozen-video
    // path needs SOME fragment to arrive, so a whole small NAL vanishing is invisible
    // to both. The monotonic per-NAL seq makes it visible — a gap means a NAL is gone.
    private var sentNALs: [UInt16: [Data]] = [:]
    private var sentOrder: [UInt16] = []
    private var highestVideoSeq = -1
    private var nackedAt: [UInt16: Date] = [:]
    private let nackWindow = 30          // only chase the last ~30 missing NALs (~0.5s of video)

    // sentNALs/sentOrder are WRITTEN by bufferSentNAL on the encoder/send thread and
    // READ by resend* on the rx queue — a real cross-thread race (Swift Dictionary is
    // not thread-safe; it SIGSEGV'd under the frequent per-fragment NACK). Guard both,
    // and copy the wire array out under the lock so rawSend (crypto) runs lock-free.
    private let nackLock = NSLock()
    private var fragNackedAt: [UInt16: Date] = [:]
    // Seqs already delivered to the decoder. NACK resends can re-complete a NAL that was
    // already handed up -> the decoder would get the SAME frame twice (recv > sent, and
    // real double-decode artifacts). Drop any fragment for an already-delivered seq. 1-1
    // only (group has no resends and shares the seq space across sources). rx-queue-only.
    private var deliveredSeqs: Set<UInt16> = []
    private var deliveredOrder: [UInt16] = []
    private func markDelivered(_ seq: UInt16) {
        guard !groupMode, deliveredSeqs.insert(seq).inserted else { return }
        deliveredOrder.append(seq)
        while deliveredOrder.count > 256 { deliveredSeqs.remove(deliveredOrder.removeFirst()) }
    }

    private func bufferSentNAL(_ seq: UInt16, _ wire: [Data]) {
        nackLock.lock()
        sentNALs[seq] = wire
        sentOrder.append(seq)
        while sentOrder.count > 64 { sentNALs.removeValue(forKey: sentOrder.removeFirst()) }
        nackLock.unlock()
    }

    // Peer asked us to re-send a whole NAL it never got. Re-seal (fresh random nonce) and wire it out.
    func resendNAL(_ seq: UInt16) {
        nackLock.lock(); let wire = sentNALs[seq]; nackLock.unlock()
        guard let wire = wire else { return }   // already evicted -> too old to help
        for w in wire { rawSend(w) }
    }

    // Peer asked for SPECIFIC missing fragments of a NAL it partly got. Data fragments
    // occupy wire[0..<total] in idx order (parities follow), so idx maps straight in.
    func resendFragments(_ seq: UInt16, _ idxs: [Int]) {
        nackLock.lock(); let wire = sentNALs[seq]; nackLock.unlock()
        guard let wire = wire else { return }
        for i in idxs where i >= 0 && i < wire.count { rawSend(wire[i]) }
    }

    // A video data fragment arrived: (1) NACK any NAL seq skipped entirely since the
    // last one (whole-NAL, since we don't know its `total`); (2) per-FRAGMENT NACK the
    // recent NALs that are partly here but still short — resend only the holes, not the
    // whole keyframe, and retry while they stay incomplete. Modular gap => u16-wrap-safe.
    private func noteVideoSeq(_ s: Int) {
        if highestVideoSeq < 0 { highestVideoSeq = s; return }
        let gap = (s - highestVideoSeq + 65536) % 65536
        if gap == 0 || gap > 32768 { return }            // duplicate / reorder / old
        let now = Date()
        if gap > 1 {
            for j in max(1, gap - nackWindow)..<gap {
                let mseq = UInt16((highestVideoSeq + j) & 0xFFFF)
                if let t = nackedAt[mseq], now.timeIntervalSince(t) < 0.12 { continue }   // rate-limit per seq
                nackedAt[mseq] = now
                send(Data([0xFD, 0x4E, UInt8(mseq & 0xFF), UInt8(mseq >> 8)]))             // "resend whole NAL mseq"
            }
            if nackedAt.count > 256 { nackedAt = nackedAt.filter { now.timeIntervalSince($0.value) < 1.0 } }
        }
        highestVideoSeq = s
        for back in 1...8 { nackMissingFragments(UInt16((s - back) & 0xFFFF), now) }   // retry recent partials
        if fragNackedAt.count > 256 { fragNackedAt = fragNackedAt.filter { now.timeIntervalSince($0.value) < 1.0 } }
    }

    // If NAL `seq` is present but short, ask for exactly its missing fragment indices.
    private func nackMissingFragments(_ seq: UInt16, _ now: Date) {
        guard let entry = fragBufs[seq], entry.have < entry.parts.count else { return }
        if let t = fragNackedAt[seq], now.timeIntervalSince(t) < 0.08 { return }         // rate-limit per NAL
        let missing = (0..<entry.parts.count).filter { entry.parts[$0] == nil }
        guard !missing.isEmpty else { return }
        fragNackedAt[seq] = now
        var pkt = Data([0xFD, 0x4F, UInt8(seq & 0xFF), UInt8(seq >> 8)])
        for idx in missing.prefix(64) { pkt.append(UInt8(idx)) }                          // idx < total <= 255
        send(pkt)
    }

    // Encrypt a fragment (group key in conference mode, else the ephemeral
    // session key) and wire it out.
    private func rawSend(_ data: Data) {
        if groupMode {
            guard let key = groupKey,
                  let box = try? ChaChaPoly.seal(data, using: key) else { return }
            rawSendWire(box.combined)
        } else {
            guard let wire = crypto.seal(data) else { return } // drop until session up
            rawSendWire(wire)
        }
    }

    // Send bytes verbatim. In conference mode, full-mesh broadcast to every
    // peer; in 1-1, just the single peer. (Handshakes are self-authenticating.)
    private func rawSendWire(_ wire: Data) {
        guard fd >= 0 else { return }
        if groupMode {
            for var pr in peers { sendOne(wire, &pr.addr) }
        } else {
            sendOne(wire, &peer)
        }
    }

    private func sendOne(_ wire: Data, _ addr: inout sockaddr_in) {
        let sent = wire.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { pp in
                pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                    sendto(fd, raw.baseAddress, wire.count, 0, s, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            sendErrCount += 1
            if sendErrCount <= 5 || sendErrCount % 500 == 0 {
                NSLog("TRINET: sendto(\(wire.count)B) failed: \(String(cString: strerror(errno))) (#\(sendErrCount))")
            }
        }
    }

    // Conference call: 2-4 peers, shared static conference key, full-mesh
    // broadcast, per-source delivery. No pairwise handshake.
    func connectGroup(peerHosts: [String], peerPort: UInt16, listenPort: UInt16) {
        disconnect()
        groupMode = true
        groupKey = MeshCrypto.groupAuthKey(room: PeerDiscovery.myRoom)   // room-bound conference key

        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { NSLog("TRINET: socket() failed"); return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, 4)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                Darwin.bind(fd, s, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { NSLog("TRINET: group bind failed"); close(fd); fd = -1; return }

        peers = peerHosts.map { ip in
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = peerPort.bigEndian
            a.sin_addr.s_addr = inet_addr(ip)
            return (a, ip)
        }
        running = true
        connected = true
        NSLog("TRINET: GROUP transport up — listen :\(listenPort), \(peers.count) peers")
        startRx(fd)
    }

    // Returns a complete NAL when the datagram finishes one, nil otherwise.
    // Multi-slot: chunks of several NALs may interleave (video + a peer
    // restart, or future multi-stream), so partial buffers are keyed by seq.
    private func reassemble(_ d: Data) -> Data? {
        // FEC parity packet (per group): store it, then try to repair that group.
        // Wire: [FA EC][seq:2][total][gStart][gLen][lastLen:2] + xor.
        if d.count > 9, d[0] == 0xFA, d[1] == 0xEC {
            let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
            let total = Int(d[4]); let gStart = Int(d[5]); let gLen = Int(d[6])
            let lastLen = Int(d[7]) | (Int(d[8]) << 8)
            guard total >= 2 else { return nil }
            fecBufs[seq, default: [:]][gStart] = (Array(d[9...]), gLen, lastLen, total)
            return tryFEC(seq, gStart)
        }
        // 0xFA is reserved for this framing layer (raw NALs start 00 00 00 01 and
        // control packets use 0xFB..0xFE). Drop an unknown 0xFA subtype instead of
        // returning it as a finished NAL — handing unknown magic to the decoder is
        // exactly what made pre-v0.9 peers storm on FEC parity.
        if d.count > 1, d[0] == 0xFA, d[1] != 0xFB { return nil }
        guard d.count > 6, d[0] == 0xFA, d[1] == 0xFB else { return d }
        let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
        let idx = Int(d[4])
        let total = Int(d[5])
        guard total > 0, idx < total else { return nil }
        if !groupMode {
            if deliveredSeqs.contains(seq) { return nil }   // resend/late dupe of a delivered NAL -> drop
            noteVideoSeq(Int(seq))                          // NACK any NAL skipped before this one
        }
        var entry = fragBufs[seq] ?? (Array(repeating: nil, count: total), 0, 0)
        if entry.parts.count != total { entry = (Array(repeating: nil, count: total), 0, 0) }
        if entry.parts[idx] == nil {
            entry.parts[idx] = d.subdata(in: 6..<d.count)
            entry.have += 1
        }
        if entry.have == total {
            fragBufs.removeValue(forKey: seq); fecBufs.removeValue(forKey: seq)
            markDelivered(seq)
            return entry.parts.compactMap { $0 }.reduce(Data(), +)
        }
        fragTick &+= 1
        entry.tick = fragTick
        fragBufs[seq] = entry
        // A data fragment may complete any group whose parity is already here.
        if let byGroup = fecBufs[seq] {
            for gStart in byGroup.keys { if let recovered = tryFEC(seq, gStart) { return recovered } }
        }
        // GC by RECENCY, never "keep only the current seq". Audio and video
        // fragments interleave, so wiping every other partial group silently
        // destroyed in-flight audio groups the moment video filled the table —
        // audio died while video kept flowing.
        if fragBufs.count > fragBufsCap {
            let keep = Set(fragBufs.sorted { $0.value.tick > $1.value.tick }
                                   .prefix(fragBufsCap).map { $0.key })
            let dropped = fragBufs.count - keep.count
            fragBufs = fragBufs.filter { keep.contains($0.key) }
            fecBufs = fecBufs.filter { keep.contains($0.key) }
            NSLog("TRINET: frag GC dropped \(dropped) stale group(s)")
        }
        return nil
    }

    // XOR-reconstruct the one missing fragment of a single GROUP from its parity.
    private func tryFEC(_ seq: UInt16, _ gStart: Int) -> Data? {
        guard let fec = fecBufs[seq]?[gStart], var entry = fragBufs[seq],
              entry.parts.count == fec.total else { return nil }
        var present = [Int: [UInt8]]()
        let end = min(gStart + fec.gLen, fec.total)
        for i in gStart..<end { if let p = entry.parts[i] { present[i] = [UInt8](p) } }
        guard let (idx, bytes) = VideoFEC.recover(parity: fec.xor, present: present, gStart: gStart,
                                                  gLen: fec.gLen, total: fec.total, lastLen: fec.lastLen,
                                                  maxPayload: maxPayload) else { return nil }
        entry.parts[idx] = Data(bytes)
        entry.have += 1
        if entry.have == fec.total {
            fragBufs.removeValue(forKey: seq); fecBufs.removeValue(forKey: seq)
            markDelivered(seq)
            return entry.parts.compactMap { $0 }.reduce(Data(), +)
        }
        fragBufs[seq] = entry
        return nil
    }

    func disconnect() {
        running = false
        handshakeTimer?.cancel(); handshakeTimer = nil
        if fd >= 0 { close(fd); fd = -1 }
        stopFeedbackListener()
        connected = false
        nackLock.lock(); sentNALs = [:]; sentOrder = []; nackLock.unlock()
        highestVideoSeq = -1; nackedAt = [:]; fragNackedAt = [:]; deliveredSeqs = []; deliveredOrder = []   // fresh per call (rx-queue-only)
    }

    deinit { disconnect() }

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
