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
    let np3d: [(id: Int, x: Double, y: Double, z: Double)] = [
        (13, 0.15, 0.15, 0.80), (11, 0.85, 0.15, 0.20),
        (12, 0.15, 0.85, 0.20), (10, 0.85, 0.85, 0.80)]

    // --- RADAR: extract a discrete target contact from the field (detection, not raw returns) ---
    // The backprojection peaks where shadowed links cross; the target = confidence-weighted centroid
    // of the hottest voxels, reported only above a detection threshold. A short trail = its track.
    struct Contact { var x: Double; var y: Double; var z: Double; var conf: Double }
    @Published var target: Contact? = nil
    @Published var trail: [Contact] = []
    private func extractTarget() {
        var peak: Float = 0
        for v in vox { if v > peak { peak = v } }
        guard peak > 0.85 else { target = nil; return }          // detection threshold
        let thr = peak * 0.62
        var sx = 0.0, sy = 0.0, sz = 0.0, sw = 0.0
        for k in 0..<gz { for j in 0..<gy { for i in 0..<gx {
            let v = Double(vox[k*gx*gy + j*gx + i])
            if Float(v) >= thr {
                sx += ((Double(i)+0.5)/Double(gx))*v; sy += ((Double(j)+0.5)/Double(gy))*v
                sz += ((Double(k)+0.5)/Double(gz))*v; sw += v
            }
        }}}
        guard sw > 0 else { target = nil; return }
        let c = Contact(x: sx/sw, y: sy/sw, z: sz/sw, conf: Double(peak))
        target = c
        trail.append(c); if trail.count > 24 { trail.removeFirst() }
    }
    private func d3(_ ax: Double,_ ay: Double,_ az: Double,_ bx: Double,_ by: Double,_ bz: Double) -> Double {
        let dx = ax-bx, dy = ay-by, dz = az-bz; return (dx*dx+dy*dy+dz*dz).squareRoot()
    }
    private func backproject3d(_ frm: Int,_ to: Int,_ v: Double) {
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
        DispatchQueue.main.async { for (idx, add) in upd { self.vox[idx] = min(3.0, self.vox[idx] + add) } }
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
        DispatchQueue.main.async { self.listening = true; self.lastMsg = "Ready :6000" }
        DispatchQueue.global().async { self.recv() }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            DispatchQueue.main.async {
                for y in 0..<30 { for x in 0..<30 { self.grid[y][x] *= 0.9 } }
                for i in self.vox.indices { self.vox[i] *= 0.86 }
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
            } else { usleep(15000) }
        }
    }
    
    func clear() { DispatchQueue.main.async {
        for y in 0..<30 { for x in 0..<30 { self.grid[y][x] = 0 } }
        for i in self.vox.indices { self.vox[i] = 0 }
        self.target = nil; self.trail.removeAll(); self.pktCount = 0
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
                        }.padding(10)
                    }
                    .background(Color.black)
                    .cornerRadius(8)
                    .padding(8)
            } else {
            // 30x30 grid of colored rectangles (floor view)
            GeometryReader { geo in
                let cw = geo.size.width / 30
                let ch = geo.size.height / 30
                ZStack {
                    Color.black
                    ForEach(0..<30, id: \.self) { y in
                        ForEach(0..<30, id: \.self) { x in
                            let v = e.grid[y][x]
                            Rectangle()
                                .fill(v > 0.02 ? col(v) : Color.clear)
                                .frame(width: cw, height: ch)
                                .position(x: CGFloat(x)*cw+cw/2, y: CGFloat(y)*ch+ch/2)
                        }
                    }
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
        }
        .background(DS.ink)
        .onAppear { e.go() }
    }
    
    func col(_ v: Double) -> Color {
        if v < 0.2 { return Color(red: 0.1, green: 0.3, blue: 0.9) }
        if v < 0.4 { return Color(red: 0.1, green: 0.8, blue: 0.2) }
        if v < 0.6 { return Color(red: 0.9, green: 0.9, blue: 0.1) }
        return Color(red: 0.9, green: 0.1, blue: 0.1)
    }
}
