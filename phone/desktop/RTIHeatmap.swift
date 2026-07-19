import SwiftUI
import Darwin

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

    // --- RADAR: extract a discrete target contact from the field (detection, not raw returns) ---
    // The backprojection peaks where shadowed links cross; the target = confidence-weighted centroid
    // of the hottest voxels, reported only above a detection threshold. A short trail = its track.
    struct Contact { var x: Double; var y: Double; var z: Double; var conf: Double }
    @Published var target: Contact? = nil
    @Published var trail: [Contact] = []
    private var wasLocked = false
    private func lostContact() {
        if wasLocked { NSLog("%@", "RTI: contact LOST"); wasLocked = false }
        target = nil
    }
    private func extractTarget() {
        // Combined evidence: static occupancy (vox) OR live MOTION (mvox, weighted a touch higher --
        // a moving body is the radar's real target). Find the single strongest voxel = the return.
        var rawPeak: Float = 0, pi = 0, pj = 0, pk = 0
        for k in 0..<gz { for j in 0..<gy { for i in 0..<gx {
            let c = max(vox[k*gx*gy + j*gx + i], mvox[k*gx*gy + j*gx + i]*1.2)
            if c > rawPeak { rawPeak = c; pi = i; pj = j; pk = k }
        }}}
        guard rawPeak > 0.45 else { lostContact(); return }          // nothing above noise
        // A radar reports ONE contact: centroid only over the strongest LOBE (voxels near the peak and
        // above 0.55*peak), so a bimodal reconstruction locks the nearest strong return instead of
        // averaging two lobes into empty space. Spatial gating is what makes it read like a radar.
        let thr = rawPeak * 0.55
        let rr = 3.0   // gate radius in cells around the peak
        var sx = 0.0, sy = 0.0, sz = 0.0, sw = 0.0
        for k in 0..<gz { for j in 0..<gy { for i in 0..<gx {
            let v = Double(max(vox[k*gx*gy + j*gx + i], mvox[k*gx*gy + j*gx + i]*1.2))
            if Float(v) >= thr {
                let dcell = (Double(i-pi)*Double(i-pi) + Double(j-pj)*Double(j-pj) + Double(k-pk)*Double(k-pk)).squareRoot()
                if dcell <= rr {
                    sx += ((Double(i)+0.5)/Double(gx))*v; sy += ((Double(j)+0.5)/Double(gy))*v
                    sz += ((Double(k)+0.5)/Double(gz))*v; sw += v
                }
            }
        }}}
        guard sw > 0 else { lostContact(); return }
        let c = Contact(x: sx/sw, y: sy/sw, z: sz/sw, conf: Double(rawPeak))
        target = c
        trail.append(c); if trail.count > 24 { trail.removeFirst() }
        if !wasLocked { NSLog("%@", String(format: "RTI: CONTACT LOCKED  x=%.2f y=%.2f height=%.2f conf=%.1f", c.x, c.y, c.z, c.conf)); wasLocked = true }
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
                self.csiDelta *= 0.82
                self.extractTarget()          // radar detection: pull the contact from the field
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
                DispatchQueue.main.async {
                    for (x,y) in pts { if x>=0&&x<30&&y>=0&&y<30 { self.grid[y][x] = min(1.0, self.grid[y][x]+v) } }
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
                DispatchQueue.main.async { self.pktCount += 1; self.lastMsg = "LIVE \(self.pktCount)" }
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
        self.target = nil; self.trail.removeAll(); self.pktCount = 0
        self.motionEnergy = 0; self.csiDelta = 0
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
                            if let t = e.target {
                                Text("● CONTACT LOCKED").font(.system(size: 12, weight: .bold)).foregroundColor(.red)
                                Text(String(format: "X %.2f  Y %.2f", t.x, t.y)).font(.system(size: 11, design: .monospaced)).foregroundColor(.orange)
                                Text(String(format: "HEIGHT %.2f  conf %.1f", t.z, t.conf)).font(.system(size: 11, design: .monospaced)).foregroundColor(.orange)
                            } else {
                                Text("○ SCANNING…").font(.system(size: 12, weight: .bold)).foregroundColor(.green)
                                Text("no contact").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                            }
                            // motion detector (VRTI: RSS variance) + CSI channel metric
                            Divider().frame(width: 130)
                            Text(e.motionEnergy > 0.22 ? "▲ MOTION" : "· still").font(.system(size: 11, weight: .bold)).foregroundColor(e.motionEnergy > 0.22 ? .yellow : .gray)
                            Text(String(format: "motion %.2f", e.motionEnergy)).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                            Text(String(format: "CSI Δ %.2f", e.csiDelta)).font(.system(size: 10, design: .monospaced)).foregroundColor(e.csiDelta > 0.2 ? .cyan : .gray)
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
