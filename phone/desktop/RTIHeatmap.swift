import SwiftUI
import Darwin
import QuartzCore

// Simple ObservableObject with BSD UDP receiver
class RTIEngine: ObservableObject {
    @Published var grid: [[Double]] = Array(repeating: Array(repeating: 0.0, count: 30), count: 30)
    @Published var pktCount = 0
    @Published var lastMsg = "Starting..."
    @Published var listening = false
    
    private var s: Int32 = -1
    private var run = false
    // Four boards at the grid corners so link paths cross meaningfully:
    // .13<->.10 is the main diagonal, .11<->.12 the anti-diagonal (both cross the centre);
    // shadowing a crossing pair lights the intersection cell -> radio tomography.
    let np = [(13, 4, 4), (11, 26, 4), (12, 4, 26), (10, 26, 26)]

    // --- 3D voxel field: radio tomography in SPACE (not just a floor view) ---
    // Ellipsoid-weight backprojection (Wilson & Patwari RTI): each link (a,b) deposits its RSS
    // attenuation into the voxels inside the ellipsoid |a-p|+|p-b|-|a-b| < lambda, weighted 1/sqrt(|a-b|).
    // The four boards sit at TWO heights so the z-axis is observable (else all links are coplanar).
    let gx = 12, gy = 12, gz = 6
    @Published var vox = [Float](repeating: 0, count: 12*12*6)
    // Node positions are MEASURED, not assumed: they start as a placeholder but are overwritten by
    // self-localization packets ([34,id,x,y,z]) once the boards range each other and solve MDS. An
    // assumed geometry makes the whole RTI map wrong -- the boards must locate themselves first.
    @Published var np3d: [(id: Int, x: Double, y: Double, z: Double)] = [
        (13, 0.15, 0.15, 0.80), (11, 0.85, 0.15, 0.20),
        (12, 0.15, 0.85, 0.20), (10, 0.85, 0.85, 0.80)]
    @Published var localized = false
    var baseRss: [Int: Double] = [:]       // per-link quiet-baseline RSS
    // VRTI (variance-based RTI): a MOVING body makes a link's RSS FLUCTUATE. Per-link recent-RSS
    // window -> variance -> a motion image. This detects MOTION, not just a static shadow -- the
    // approach that works through walls (Wilson & Patwari, "See-Through Walls", 2009).
    var rssHist: [Int: [Double]] = [:]
    @Published var motionEnergy = 0.0      // total motion right now (for the MOTION indicator)
    // Option B -- a SEPARATE motion voxel field. Each link's RSS VARIANCE is backprojected here, so
    // where moving-link ellipsoids cross the motion peaks: a MOVING POINT in space, not a scalar.
    // Decays slower than the occupancy field so a slow real (TDM) feed still sustains a lock.
    @Published var mvox = [Float](repeating: 0, count: 12*12*6)
    // Option C -- CSI (per-subcarrier channel response, not just one scalar RSS). A moving body reshapes
    // the frequency-selective fading; the spread of |H| ACROSS bins is a finer motion cue than mean RSS.
    var csiHist: [Int: [Double]] = [:]     // per-link recent cross-bin spread
    @Published var csiDelta = 0.0          // live CSI motion metric (envelope-CSI proxy for 802.11bf)
    // Complex CSI phase (option C): per-link previous cross-bin phase-difference vector. The cross-bin
    // difference cancels the common CFO/timing offset between two independent oscillators, so its
    // temporal change is a CFO-robust micro-motion cue (sub-cm sensitivity at 2.4 GHz).
    var csiPhasePrev: [Int: [Double]] = [:]
    @Published var csiPhase = 0.0

    // --- RADAR: MULTI-TARGET tracker with a constant-velocity smoother (option A) ---
    // The field is scanned for up to K separated peaks (greedy non-max suppression); each detection is
    // associated to an existing TRACK (nearest within a gate) and fused with an alpha-beta filter (the
    // steady-state Kalman for a constant-velocity target): it SMOOTHS the jitter and PREDICTS the
    // position while a detection is missing (coasting), so the radar can follow 2-3 people at once and
    // does not blink out on a single dropped frame.
    struct Contact { var x: Double; var y: Double; var z: Double; var conf: Double }
    struct Track: Identifiable { var id: Int; var x: Double; var y: Double; var z: Double
        var vx: Double; var vy: Double; var vz: Double; var conf: Double; var hits: Int; var misses: Int
        var trail: [Contact]; var ghost: Bool = false
        var bpm: Double = 0; var hr: Double = 0; var vconf: Double = 0 }
    // Vital signs: a chest wall moving with breathing/heartbeat periodically modulates the CSI phase.
    // We buffer the (CFO-robust) phase signal PER LINK and attribute it to the nearest tracked person.
    var csiPhaseSeries: [(t: Double, v: Double)] = []              // global (strongest link) fallback
    var csiLinkSeries: [Int: [(t: Double, v: Double)]] = [:]       // per-link phase history (key frm*100+to)
    var activeLinks: [Int: Double] = [:]                          // recently-shadowed links -> last-seen time (JPDA)
    @Published var breathBpm = 0.0
    @Published var vitalConf = 0.0
    // Perimeter security (product demo): a restricted zone; a tracked PERSON entering it raises an alarm
    // and the event is logged (copyable). Zone near the .11 corner in normalized floor coords.
    let zoneX0 = 0.60, zoneX1 = 0.92, zoneY0 = 0.08, zoneY1 = 0.40
    @Published var alarm = false
    private var inZoneIds = Set<Int>()
    @Published var target: Contact? = nil          // strongest confirmed track (primary readout)
    @Published var trail: [Contact] = []           // primary track's history
    @Published var contacts: [Track] = []          // all confirmed tracks (for multi-blip render)
    private var tracks: [Track] = []
    private var nextTrackId = 1

    // greedy non-max suppression: up to maxK separated peak-centroids of the combined field
    private func detectPeaks(_ maxK: Int) -> [Contact] {
        let n = vox.count
        var field = [Float](repeating: 0, count: n)
        var gmax: Float = 0
        for i in 0..<n { let c = max(vox[i], mvox[i]*1.2); field[i] = c; if c > gmax { gmax = c } }
        guard gmax > 0.45 else { return [] }
        let floor = gmax * 0.62
        var out: [Contact] = []
        for _ in 0..<maxK {
            var pk: Float = 0, pi = 0, pj = 0, pkk = 0
            for k in 0..<gz { for j in 0..<gy { for i in 0..<gx {
                let idx = k*gx*gy + j*gx + i; if field[idx] > pk { pk = field[idx]; pi = i; pj = j; pkk = k } } } }
            if pk < floor { break }
            let thr = pk * 0.6
            var sx = 0.0, sy = 0.0, sz = 0.0, sw = 0.0
            for k in 0..<gz { for j in 0..<gy { for i in 0..<gx {
                let idx = k*gx*gy + j*gx + i; let v = Double(field[idx])
                let dc = (Double(i-pi)*Double(i-pi)+Double(j-pj)*Double(j-pj)+Double(k-pkk)*Double(k-pkk)).squareRoot()
                if field[idx] >= thr && dc <= 3.0 {
                    sx += ((Double(i)+0.5)/Double(gx))*v; sy += ((Double(j)+0.5)/Double(gy))*v
                    sz += ((Double(k)+0.5)/Double(gz))*v; sw += v
                }
            }}}
            if sw > 0 { out.append(Contact(x: sx/sw, y: sy/sw, z: sz/sw, conf: Double(pk))) }
            // suppress a neighbourhood around this peak so the next iteration finds a DIFFERENT target
            for k in 0..<gz { for j in 0..<gy { for i in 0..<gx {
                let dc = (Double(i-pi)*Double(i-pi)+Double(j-pj)*Double(j-pj)+Double(k-pkk)*Double(k-pkk)).squareRoot()
                if dc <= 3.5 { field[k*gx*gy + j*gx + i] = 0 } } } }
        }
        return out
    }

    private func extractTargets() {
        // predict every track forward (constant velocity) -- this is the coast during a missing frame
        for i in tracks.indices { tracks[i].x += tracks[i].vx; tracks[i].y += tracks[i].vy; tracks[i].z += tracks[i].vz }
        let dets = detectPeaks(3)
        var used = Set<Int>()
        let alpha = 0.55, beta = 0.20, gate = 0.30
        for i in tracks.indices {
            var best = -1; var bd = gate
            for (di, d) in dets.enumerated() where !used.contains(di) {
                let dd = ((d.x-tracks[i].x)*(d.x-tracks[i].x)+(d.y-tracks[i].y)*(d.y-tracks[i].y)+(d.z-tracks[i].z)*(d.z-tracks[i].z)).squareRoot()
                if dd < bd { bd = dd; best = di }
            }
            if best >= 0 {
                used.insert(best); let d = dets[best]
                let rx = d.x-tracks[i].x, ry = d.y-tracks[i].y, rz = d.z-tracks[i].z   // innovation
                tracks[i].x += alpha*rx; tracks[i].vx += beta*rx
                tracks[i].y += alpha*ry; tracks[i].vy += beta*ry
                tracks[i].z += alpha*rz; tracks[i].vz += beta*rz
                tracks[i].conf = d.conf; tracks[i].hits += 1; tracks[i].misses = 0
                tracks[i].trail.append(Contact(x: tracks[i].x, y: tracks[i].y, z: tracks[i].z, conf: tracks[i].conf))
                if tracks[i].trail.count > 20 { tracks[i].trail.removeFirst() }
            } else { tracks[i].misses += 1 }
        }
        // unmatched detections seed new tracks
        for (di, d) in dets.enumerated() where !used.contains(di) {
            tracks.append(Track(id: nextTrackId, x: d.x, y: d.y, z: d.z, vx: 0, vy: 0, vz: 0,
                                conf: d.conf, hits: 1, misses: 0,
                                trail: [Contact(x: d.x, y: d.y, z: d.z, conf: d.conf)]))
            NSLog("%@", String(format: "RTI: TRACK #%d LOCKED  x=%.2f y=%.2f height=%.2f", nextTrackId, d.x, d.y, d.z))
            nextTrackId += 1
        }
        // clamp velocity (bound the coast) and cull dead tracks
        let vmax = 0.14
        for i in tracks.indices {
            tracks[i].vx = max(-vmax, min(vmax, tracks[i].vx))
            tracks[i].vy = max(-vmax, min(vmax, tracks[i].vy))
            tracks[i].vz = max(-vmax, min(vmax, tracks[i].vz))
        }
        // merge tracks that have converged onto the same body (keep the more-established one)
        var mi = 0
        while mi < tracks.count {
            var mj = mi + 1
            while mj < tracks.count {
                let dd = ((tracks[mi].x-tracks[mj].x)*(tracks[mi].x-tracks[mj].x)+(tracks[mi].y-tracks[mj].y)*(tracks[mi].y-tracks[mj].y)+(tracks[mi].z-tracks[mj].z)*(tracks[mi].z-tracks[mj].z)).squareRoot()
                if dd < 0.20 {
                    if tracks[mj].hits > tracks[mi].hits { tracks[mi] = tracks[mj] }
                    tracks.remove(at: mj)
                } else { mj += 1 }
            }
            mi += 1
        }
        for t in tracks where t.misses > 6 { NSLog("%@", String(format: "RTI: TRACK #%d LOST", t.id)) }
        tracks.removeAll { $0.misses > 6 }
        // publish confirmed tracks (survived >=3 frames, still fresh) -- strongest is the primary
        var confirmed = tracks.filter { $0.hits >= 3 && $0.misses <= 2 }.sorted { $0.conf > $1.conf }
        // Option B -- JPDA "explaining away": assign each recently-shadowed link to the track NEAREST
        // its path. A track that OWNS no link is fully explained by the others -> a phantom (the RTI
        // crossing ghost). This resolves N people (even collinear) -- each real body owns its own links;
        // only a true crossing ghost owns none.
        let now = CACurrentMediaTime()
        var owned = [Int](repeating: 0, count: confirmed.count)
        var anyLink = false
        for (lk, t) in activeLinks where now - t < 2.5 {
            guard let na = np3d.first(where: { $0.id == lk/100 }), let nb = np3d.first(where: { $0.id == lk%100 }) else { continue }
            anyLink = true
            var best = -1; var bd = 0.26
            for i in confirmed.indices {
                let d = distPointSeg(confirmed[i].x, confirmed[i].y, confirmed[i].z, na.x, na.y, na.z, nb.x, nb.y, nb.z)
                if d < bd { bd = d; best = i }
            }
            if best >= 0 { owned[best] += 1 }
        }
        if anyLink && confirmed.count > 1 { for i in confirmed.indices where owned[i] == 0 { confirmed[i].ghost = true } }
        // Option A -- per-person vitals: attribute the nearest shadowed link's CSI-phase series to each
        // real track and extract its respiration (0.12-0.5 Hz) and cardiac (0.8-2.0 Hz) rates.
        for i in confirmed.indices where !confirmed[i].ghost {
            if let lk = nearestActiveLink(confirmed[i]), let ser = csiLinkSeries[lk] {
                let v = vitalOfSeries(ser); confirmed[i].bpm = v.resp; confirmed[i].hr = v.card; confirmed[i].vconf = v.conf
            }
        }
        contacts = confirmed
        if let p = confirmed.first(where: { !$0.ghost }) { target = Contact(x: p.x, y: p.y, z: p.z, conf: p.conf); trail = p.trail }
        else { target = nil }
        // Option C -- perimeter alarm: a real person inside the restricted zone breaches it; log entry/exit.
        var breach = false; var nowIn = Set<Int>()
        for t in confirmed where !t.ghost {
            if t.x >= zoneX0 && t.x <= zoneX1 && t.y >= zoneY0 && t.y <= zoneY1 {
                nowIn.insert(t.id); breach = true
                if !inZoneIds.contains(t.id) { NSLog("%@", String(format: "ALARM: INTRUSION track #%d entered zone at x=%.2f y=%.2f", t.id, t.x, t.y)) }
            }
        }
        for id in inZoneIds where !nowIn.contains(id) { NSLog("%@", String(format: "track #%d left the zone", id)) }
        inZoneIds = nowIn; alarm = breach
    }
    // distance from point p to the segment (a,b) in 3D
    private func distPointSeg(_ px: Double,_ py: Double,_ pz: Double,_ ax: Double,_ ay: Double,_ az: Double,_ bx: Double,_ by: Double,_ bz: Double) -> Double {
        let dx = bx-ax, dy = by-ay, dz = bz-az; let L2 = dx*dx+dy*dy+dz*dz
        if L2 < 1e-9 { return 9 }
        let t = max(0, min(1, ((px-ax)*dx+(py-ay)*dy+(pz-az)*dz)/L2))
        let cx = ax+t*dx, cy = ay+t*dy, cz = az+t*dz
        return ((px-cx)*(px-cx)+(py-cy)*(py-cy)+(pz-cz)*(pz-cz)).squareRoot()
    }
    // the active shadowed link whose path passes closest to this track (its likely vital source)
    private func nearestActiveLink(_ p: Track) -> Int? {
        let now = CACurrentMediaTime(); var best: Int? = nil; var bd = 0.42
        for (lk, t) in activeLinks where now - t < 3.0 {
            guard let na = np3d.first(where: { $0.id == lk/100 }), let nb = np3d.first(where: { $0.id == lk%100 }) else { continue }
            let d = distPointSeg(p.x, p.y, p.z, na.x, na.y, na.z, nb.x, nb.y, nb.z)
            if d < bd { bd = d; best = lk }
        }
        return best
    }

    // Option C vital signs: scan a CSI-phase series for a periodic peak in a band. Irregular
    // (packet-driven) sampling -> a direct DFT over the ACTUAL timestamps (Lomb-style), no fixed rate.
    private func bandPeak(_ s: [(t: Double, v: Double)], _ f0: Double, _ f1: Double, _ df: Double) -> (bpm: Double, ratio: Double) {
        guard s.count >= 16 else { return (0, 0) }
        let t0 = s[0].t; let ts = s.map { $0.t - t0 }
        guard let span = ts.last, span > 8 else { return (0, 0) }
        let mean = s.map { $0.v }.reduce(0,+)/Double(s.count)
        let v = s.map { $0.v - mean }                          // detrend (remove DC)
        var bestF = 0.0, bestP = 0.0, totP = 0.0; var nb = 0
        var f = f0
        while f <= f1 {
            var re = 0.0, im = 0.0
            for k in 0..<v.count { let a = 2*Double.pi*f*ts[k]; re += v[k]*Foundation.cos(a); im += v[k]*Foundation.sin(a) }
            let p = re*re + im*im; totP += p; nb += 1
            if p > bestP { bestP = p; bestF = f }
            f += df
        }
        return (bestF*60, bestP/max(1e-9, totP/Double(max(1, nb))))
    }
    // respiration (0.12-0.5 Hz = 7-30 br/min) + cardiac (0.8-2.0 Hz = 48-120 bpm) from one series
    private func vitalOfSeries(_ s: [(t: Double, v: Double)]) -> (resp: Double, card: Double, conf: Double) {
        let r = bandPeak(s, 0.12, 0.50, 0.01)
        let c = bandPeak(s, 0.80, 2.00, 0.02)
        let card = c.ratio > 6.0 ? c.bpm : 0     // only report a heartbeat if its peak is really periodic
        return (r.bpm, card, min(1.0, r.ratio/8.0))
    }
    private func computeVital() {
        let v = vitalOfSeries(csiPhaseSeries)
        breathBpm = v.resp; vitalConf = v.conf
    }
    private func d3(_ ax: Double,_ ay: Double,_ az: Double,_ bx: Double,_ by: Double,_ bz: Double) -> Double {
        let dx = ax-bx, dy = ay-by, dz = az-bz; return (dx*dx+dy*dy+dz*dz).squareRoot()
    }
    private func backproject3d(_ frm: Int,_ to: Int,_ v: Double, motion: Bool = false) {
        guard let a = np3d.first(where: { $0.id == frm }), let b = np3d.first(where: { $0.id == to }) else { return }
        let dab = d3(a.x,a.y,a.z, b.x,b.y,b.z)
        let w = Float(v / dab.squareRoot())
        let lam = 0.14
        var upd: [(Int, Float)] = []
        for k in 0..<gz { for j in 0..<gy { for i in 0..<gx {
            let px = (Double(i)+0.5)/Double(gx), py = (Double(j)+0.5)/Double(gy), pz = (Double(k)+0.5)/Double(gz)
            let excess = d3(a.x,a.y,a.z, px,py,pz) + d3(px,py,pz, b.x,b.y,b.z) - dab
            if excess < lam { upd.append((k*gx*gy + j*gx + i, w)) }
        }}}
        DispatchQueue.main.async {
            if motion { for (idx, add) in upd { self.mvox[idx] = min(3.0, self.mvox[idx] + add) } }
            else      { for (idx, add) in upd { self.vox[idx]  = min(3.0, self.vox[idx]  + add) } }
        }
    }
    
    func go() {
        guard !run else { return }
        run = true
        s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, 4)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(6000).bigEndian
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { DispatchQueue.main.async { self.lastMsg = "bind fail" }; return }
        let f = fcntl(s, F_GETFL, 0); _ = fcntl(s, F_SETFL, f | O_NONBLOCK)
        LogBus.shared.start()                 // tee stderr into the shared Log pane (copyable)
        NSLog("%@", "RTI: listening on :6000  nodes=\(np3d.map { $0.id })")
        DispatchQueue.main.async { self.listening = true; self.lastMsg = "Ready :6000" }
        DispatchQueue.global().async { self.recv() }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            DispatchQueue.main.async {
                for y in 0..<30 { for x in 0..<30 { self.grid[y][x] *= 0.9 } }
                for i in self.vox.indices { self.vox[i] *= 0.86 }
                for i in self.mvox.indices { self.mvox[i] *= 0.90 }   // motion persists a touch longer
                self.motionEnergy *= 0.82                             // decay stale motion (was frozen -> lied)
                self.csiDelta *= 0.82; self.csiPhase *= 0.82
                self.extractTargets()         // radar detection + multi-target tracking
                self.computeVital()           // breathing-rate estimate from the CSI-phase time-series
            }
        }
    }
    
    private func recv() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while run {
            let n = buf.withUnsafeMutableBufferPointer { recvfrom(s, $0.baseAddress!, 2048, 0, nil, nil) }
            if n >= 5 && buf[0] == 33 {
                let frm = Int(buf[1]), to = Int(buf[2])
                let v = Double(buf[4]) / 255.0
                let ax = np.first(where: { $0.0 == frm })?.1 ?? 10
                let ay = np.first(where: { $0.0 == frm })?.2 ?? 15
                let bx = np.first(where: { $0.0 == to })?.1 ?? 20
                let by = np.first(where: { $0.0 == to })?.2 ?? 15
                var x0 = ax, y0 = ay; let x1 = bx, y1 = by
                let dx = abs(x1-x0), dy = abs(y1-y0)
                let sx = x0<x1 ?1:-1, sy = y0<y1 ?1:-1
                var err = dx-dy, pts: [(Int,Int)] = []
                while true { pts.append((x0,y0)); if x0==x1 && y0==y1 {break}; let e2=2*err; if e2 > (-dy) {err -= dy; x0 += sx}; if e2 < dx {err += dx; y0 += sy} }
                let nowT = CACurrentMediaTime()
                DispatchQueue.main.async {
                    for (x,y) in pts { if x>=0&&x<30&&y>=0&&y<30 { self.grid[y][x] = min(1.0, self.grid[y][x]+v) } }
                    self.activeLinks[frm*100+to] = nowT           // shadowed link (JPDA evidence)
                    self.pktCount += 1; self.lastMsg = "LIVE \(self.pktCount)"
                }
                self.backproject3d(frm, to, v)      // 3D voxel tomography from the same packet
            } else if n >= 5 && buf[0] == 35 {
                // REAL radio: raw link RSS [35, frm, to, rss_hi, rss_lo]. Learn a quiet baseline per
                // link (EWMA when the signal is near its baseline) and detect a DROP below it -- a
                // real body shadowing the link. This is VRTI: the map reacts to actual RF, not a feed.
                let frm = Int(buf[1]), to = Int(buf[2])
                let rss = Double(Int(buf[3]) << 8 | Int(buf[4]))
                let key = frm*1000 + to
                let base = self.baseRss[key] ?? rss
                if rss >= base*0.82 { self.baseRss[key] = 0.15*rss + 0.85*base }   // quiet -> track baseline
                // VRTI: window of recent RSS -> std -> MOTION (a moving body fluctuates the link)
                var h = self.rssHist[key] ?? []; h.append(rss); if h.count > 8 { h.removeFirst() }
                self.rssHist[key] = h
                let m = h.reduce(0,+)/Double(h.count)
                let sd = (h.map { ($0-m)*($0-m) }.reduce(0,+)/Double(h.count)).squareRoot()
                let motion = min(1.0, sd/max(1.0, base*0.13))                 // VRTI: variance -> motion
                let drop = max(0.0, min(1.0, (base - rss)/max(1.0, base)))    // static shadow (occupancy)
                DispatchQueue.main.async { self.motionEnergy = 0.7*self.motionEnergy + 0.3*motion }
                // Option B -- real VRTI LOCALIZATION: backproject the per-link VARIANCE into the motion
                // field so where moving-link ellipsoids cross, the motion peaks -> a MOVING point in
                // space (extracted by the radar), not just a scalar energy bar.
                if motion > 0.12 { self.backproject3d(frm, to, motion, motion: true) }
                // static occupancy still lights the 2D floor + the occupancy field
                if drop > 0.15 {
                    let ax = np.first(where: { $0.0 == frm })?.1 ?? 10, ay = np.first(where: { $0.0 == frm })?.2 ?? 15
                    let bx = np.first(where: { $0.0 == to })?.1 ?? 20, by = np.first(where: { $0.0 == to })?.2 ?? 15
                    var x0=ax, y0=ay; let x1=bx, y1=by
                    let dx=abs(x1-x0), dy=abs(y1-y0); let sx = x0<x1 ?1:-1, sy = y0<y1 ?1:-1
                    var err=dx-dy, pts:[(Int,Int)]=[]
                    while true { pts.append((x0,y0)); if x0==x1 && y0==y1 {break}; let e2=2*err; if e2 > (-dy){err-=dy; x0+=sx}; if e2<dx{err+=dx; y0+=sy} }
                    DispatchQueue.main.async { for (x,y) in pts { if x>=0&&x<30&&y>=0&&y<30 { self.grid[y][x]=min(1.0,self.grid[y][x]+drop) } } }
                    self.backproject3d(frm, to, drop)
                }
                let act = motion > 0.12 || drop > 0.15; let nowT = CACurrentMediaTime()
                DispatchQueue.main.async { if act { self.activeLinks[frm*100+to] = nowT }; self.pktCount += 1; self.lastMsg = "LIVE \(self.pktCount)" }
            } else if n >= 4 && buf[0] == 36 {
                // Option C -- CSI: [36, frm, to, nb, b0..b_{nb-1}] = per-subcarrier |H| envelope (0..255).
                // A moving body reshapes the frequency-selective fading; the change of the |H| SHAPE
                // across bins (not just its mean) is a finer motion cue -- the 802.11bf-style feature,
                // here as an envelope-CSI proxy computed from a wideband probe on the AD9361.
                let frm = Int(buf[1]), to = Int(buf[2]); let nb = min(Int(buf[3]), n-4)
                guard nb >= 2 else { usleep(2000); continue }
                var bins = [Double](repeating: 0, count: nb)
                for i in 0..<nb { bins[i] = Double(buf[4+i]) }
                let bm = bins.reduce(0,+)/Double(nb)
                let spread = (bins.map { ($0-bm)*($0-bm) }.reduce(0,+)/Double(nb)).squareRoot()  // cross-bin |H| spread
                let key = frm*1000 + to
                var ch = self.csiHist[key] ?? []; ch.append(spread); if ch.count > 8 { ch.removeFirst() }
                self.csiHist[key] = ch
                let cm = ch.reduce(0,+)/Double(ch.count)
                let csd = (ch.map { ($0-cm)*($0-cm) }.reduce(0,+)/Double(ch.count)).squareRoot()  // temporal change of the shape
                let csi = min(1.0, csd/max(1.0, bm*0.08))
                DispatchQueue.main.async { self.csiDelta = 0.7*self.csiDelta + 0.3*csi }
                if csi > 0.12 { self.backproject3d(frm, to, csi, motion: true) }   // CSI feeds the same motion field
                DispatchQueue.main.async { self.pktCount += 1; self.lastMsg = "CSI \(self.pktCount)" }
            } else if n >= 4 && buf[0] == 37 {
                // Complex CSI PHASE [37, frm, to, nb, p0..] -- per-subcarrier phase (0..255 -> 0..2pi).
                let frm = Int(buf[1]), to = Int(buf[2]); let nb = min(Int(buf[3]), n-4)
                guard nb >= 2 else { usleep(2000); continue }
                var ph = [Double](repeating: 0, count: nb)
                for i in 0..<nb { ph[i] = Double(buf[4+i]) / 255.0 * 2.0 * Double.pi }
                // cross-bin phase differences -- the common CFO/timing phase cancels here
                var d = [Double](repeating: 0, count: nb-1)
                for i in 0..<nb-1 { var x = ph[i+1]-ph[i]; while x > Double.pi { x -= 2*Double.pi }; while x < -Double.pi { x += 2*Double.pi }; d[i] = x }
                let key = frm*1000 + to
                var mv = 0.0
                if let prev = self.csiPhasePrev[key], prev.count == d.count {
                    var s = 0.0
                    for i in 0..<d.count { var e = d[i]-prev[i]; while e > Double.pi { e -= 2*Double.pi }; while e < -Double.pi { e += 2*Double.pi }; s += abs(e) }
                    mv = s/Double(d.count)                 // mean circular change of the phase-diff vector
                }
                self.csiPhasePrev[key] = d
                let phm = min(1.0, mv/0.6)                 // 0.6 rad avg change ~ strong micro-motion
                // vital-signs signal: the mean cross-bin phase (CFO-robust) sampled over time
                let meanD = d.reduce(0,+)/Double(d.count)
                let now = CACurrentMediaTime(); let lk = frm*100 + to
                DispatchQueue.main.async {
                    self.csiPhase = 0.7*self.csiPhase + 0.3*phm
                    self.csiPhaseSeries.append((now, meanD))
                    while let f = self.csiPhaseSeries.first, now - f.t > 40 { self.csiPhaseSeries.removeFirst() }
                    var ls = self.csiLinkSeries[lk] ?? []; ls.append((now, meanD))
                    while let f = ls.first, now - f.t > 40 { ls.removeFirst() }
                    self.csiLinkSeries[lk] = ls
                    self.activeLinks[lk] = now                    // a link carrying live CSI is "present"
                }
                if phm > 0.15 { self.backproject3d(frm, to, phm, motion: true) }
                DispatchQueue.main.async { self.pktCount += 1; self.lastMsg = "CSIφ \(self.pktCount)" }
            } else if n >= 5 && buf[0] == 34 {
                // self-localization: a board's MEASURED position [34, id, x, y, z] (0..255 -> 0..1)
                let id = Int(buf[1])
                let x = Double(buf[2])/255.0, y = Double(buf[3])/255.0, z = Double(buf[4])/255.0
                DispatchQueue.main.async {
                    if let k = self.np3d.firstIndex(where: { $0.id == id }) { self.np3d[k] = (id, x, y, z) }
                    else { self.np3d.append((id, x, y, z)) }
                    self.localized = true
                }
                NSLog("%@", String(format: "SELF-LOC: node .%d at (%.2f, %.2f, %.2f)  [measured, MDS]", id, x, y, z))
            } else { usleep(15000) }
        }
    }
    
    func clear() { DispatchQueue.main.async {
        for y in 0..<30 { for x in 0..<30 { self.grid[y][x] = 0 } }
        for i in self.vox.indices { self.vox[i] = 0 }
        for i in self.mvox.indices { self.mvox[i] = 0 }
        self.target = nil; self.trail.removeAll(); self.contacts.removeAll(); self.tracks.removeAll(); self.pktCount = 0
        self.motionEnergy = 0; self.csiDelta = 0; self.csiPhase = 0
        self.csiPhaseSeries.removeAll(); self.csiLinkSeries.removeAll(); self.activeLinks.removeAll()
        self.breathBpm = 0; self.vitalConf = 0; self.alarm = false; self.inZoneIds.removeAll()
    } }
}

struct RTIHeatmapView: View {
    @ObservedObject var e: RTIEngine
    @State private var threeD = true          // 3D volumetric view is the default — presence in SPACE

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("RTI HEATMAP").font(DS.display(15, .semibold)).tracking(0.5).foregroundColor(DS.text)
                Picker("", selection: $threeD) {
                    Text("3D").tag(true)
                    Text("2D floor").tag(false)
                }.pickerStyle(.segmented).frame(width: 150).labelsHidden()
                Spacer()
                Text(e.lastMsg).font(.caption).foregroundColor(e.listening ? .green : .orange)
            }.padding(8)

            if threeD {
                // 3D RADAR: volumetric returns + extracted target contact (orbit with the mouse)
                RTI3DView(e: e)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 3) {
                            if e.alarm {
                                Text("⚠ INTRUSION ALARM").font(.system(size: 13, weight: .heavy)).foregroundColor(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.red).cornerRadius(4)
                            }
                            if e.contacts.isEmpty {
                                Text("○ SCANNING…").font(.system(size: 12, weight: .bold)).foregroundColor(.green)
                                Text("no contact").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                            } else {
                                let people = e.contacts.filter { !$0.ghost }.count
                                Text("● \(people) PERSON\(people == 1 ? "" : "S")").font(.system(size: 12, weight: .bold)).foregroundColor(.red)
                                ForEach(e.contacts) { c in
                                    let vital = (!c.ghost && c.vconf > 0.5) ? String(format: "  \u{2665}%.0fbr%@", c.bpm, c.hr > 0 ? String(format: " %.0fhr", c.hr) : "") : ""
                                    let tag = c.ghost ? "  ghost" : (c.misses > 0 ? "  ~pred" : "")
                                    Text(String(format: "#%d  X %.2f Y %.2f H %.2f%@%@", c.id, c.x, c.y, c.z, tag, vital))
                                        .font(.system(size: 11, design: .monospaced)).foregroundColor(c.ghost ? .gray : (c.vconf > 0.5 ? .pink : (c.misses > 0 ? .yellow : .orange)))
                                }
                            }
                            // motion detector (VRTI: RSS variance) + CSI channel metric
                            Divider().frame(width: 130)
                            Text(e.motionEnergy > 0.22 ? "▲ MOTION" : "· still").font(.system(size: 11, weight: .bold)).foregroundColor(e.motionEnergy > 0.22 ? .yellow : .gray)
                            Text(String(format: "motion %.2f", e.motionEnergy)).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                            Text(String(format: "CSI|H| %.2f", e.csiDelta)).font(.system(size: 10, design: .monospaced)).foregroundColor(e.csiDelta > 0.2 ? .cyan : .gray)
                            Text(String(format: "CSI\u{03C6} %.2f", e.csiPhase)).font(.system(size: 10, design: .monospaced)).foregroundColor(e.csiPhase > 0.2 ? .cyan : .gray)
                            // vital signs (option C): breathing rate from the CSI-phase spectrum
                            if e.vitalConf > 0.5 {
                                Text(String(format: "\u{2665} BREATHING %.0f bpm", e.breathBpm)).font(.system(size: 11, weight: .bold)).foregroundColor(.pink)
                            } else {
                                Text("\u{2665} vitals —").font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                            }
                        }.padding(10)
                    }
                    .background(Color.black)
                    .cornerRadius(8)
                    .padding(8)
            } else {
            // smooth 2D floor heatmap (blurred field -> a continuous tomographic image, not blocks)
            GeometryReader { geo in
                let cw = geo.size.width / 30
                let ch = geo.size.height / 30
                ZStack {
                    Color.black
                    // the field, blurred into a smooth heatmap
                    ZStack {
                        ForEach(0..<30, id: \.self) { y in
                            ForEach(0..<30, id: \.self) { x in
                                let v = e.grid[y][x]
                                Rectangle()
                                    .fill(v > 0.02 ? col(v) : Color.clear)
                                    .frame(width: cw*1.6, height: ch*1.6)
                                    .position(x: CGFloat(x)*cw+cw/2, y: CGFloat(y)*ch+ch/2)
                            }
                        }
                    }.blur(radius: max(cw, ch)*1.1)
                    // node markers on top (sharp)
                    ForEach(0..<e.np.count, id: \.self) { i in
                        let n = e.np[i]
                        Text("\(n.0)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Color.blue)
                            .clipShape(Circle())
                            .position(x: CGFloat(n.1)*cw, y: CGFloat(n.2)*ch)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .cornerRadius(8)
            .padding(8)
            }
            
            HStack {
                Text("Pkts: \(e.pktCount)").font(.caption).foregroundColor(.green)
                Spacer()
                Button("Clear") { e.clear() }.font(.caption)
            }.padding(8)

            // copyable log (same shared LogBus + Copy-All as the call screen)
            Hairline()
            LogPane(bus: LogBus.shared)
                .frame(height: 150)
                .background(DS.ink)
        }
        .background(DS.ink)
        .onAppear { e.go() }
    }
    
    // smooth perceptual heatmap: blue -> cyan -> green -> yellow -> red
    func col(_ v: Double) -> Color {
        let t = max(0, min(1, v))
        let r, g, b: Double
        if t < 0.25 { r = 0.1; g = 0.3 + t*2.0; b = 0.95 }
        else if t < 0.5 { r = 0.1; g = 0.85; b = 0.9 - (t-0.25)*3.2 }
        else if t < 0.75 { r = 0.1 + (t-0.5)*3.4; g = 0.9; b = 0.1 }
        else { r = 0.95; g = 0.9 - (t-0.75)*3.2; b = 0.1 }
        return Color(red: r, green: g, blue: b)
    }
}
