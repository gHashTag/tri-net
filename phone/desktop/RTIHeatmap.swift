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
    let np = [(12, 3, 15), (13, 27, 15), (11, 15, 3)]
    
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
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async { for y in 0..<30 { for x in 0..<30 { self.grid[y][x] *= 0.9 } } }
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
            } else { usleep(15000) }
        }
    }
    
    func clear() { DispatchQueue.main.async { for y in 0..<30 { for x in 0..<30 { self.grid[y][x] = 0 } }; self.pktCount = 0 } }
}

struct RTIHeatmapView: View {
    @ObservedObject var e: RTIEngine
    
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("RTI").font(.headline).foregroundColor(.white)
                Spacer()
                Text(e.lastMsg).font(.caption).foregroundColor(e.listening ? .green : .orange)
            }.padding(8)
            
            // 30x30 grid of colored rectangles
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
            
            HStack {
                Text("Pkts: \(e.pktCount)").font(.caption).foregroundColor(.green)
                Spacer()
                Button("Clear") { e.clear() }.font(.caption)
            }.padding(8)
        }
        .background(Color(white: 0.06))
        .onAppear { e.go() }
    }
    
    func col(_ v: Double) -> Color {
        if v < 0.2 { return Color(red: 0.1, green: 0.3, blue: 0.9) }
        if v < 0.4 { return Color(red: 0.1, green: 0.8, blue: 0.2) }
        if v < 0.6 { return Color(red: 0.9, green: 0.9, blue: 0.1) }
        return Color(red: 0.9, green: 0.1, blue: 0.1)
    }
}
