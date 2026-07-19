import SwiftUI
import SceneKit

// 3D RADAR display of radio tomography. The raw voxel field is dim "returns"; the RTIEngine extracts
// a discrete CONTACT (peak-centroid above a detection threshold) rendered as a bright blip with a
// drop-line to the floor, a pulsing range ring, and a fading track -- so it reads like a radar:
// a target moving in SPACE (x, y, height), not a blob. Orbit with the mouse.
struct RTI3DView: NSViewRepresentable {
    @ObservedObject var e: RTIEngine

    func makeCoordinator() -> Coord { Coord(e) }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = context.coordinator.scene
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling2X
        context.coordinator.attach(v)
        return v
    }
    func updateNSView(_ nsView: SCNView, context: Context) {}

    final class Coord {
        let e: RTIEngine
        let scene = SCNScene()
        private var voxNodes: [SCNNode] = []
        private var trailNodes: [SCNNode] = []
        private var nodeMarkers: [(id: Int, sphere: SCNNode, label: SCNNode)] = []
        private let targetNode = SCNNode()
        private let dropLine = SCNNode()
        private let ring = SCNNode()
        private var timer: Timer?

        init(_ e: RTIEngine) { self.e = e; build() }

        // engine coords (x,y,z in [0,1]) -> centred SceneKit space; engine z is UP (SceneKit Y)
        private func pos(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
            SCNVector3((x-0.5)*2.0, (z-0.5)*2.0, (y-0.5)*2.0)
        }
        private let floorY: CGFloat = -1.0

        private func build() {
            // bounding cube (wireframe)
            let cube = SCNBox(width: 2, height: 2, length: 2, chamferRadius: 0)
            let cm = SCNMaterial(); cm.fillMode = .lines
            cm.diffuse.contents = NSColor(white: 0.28, alpha: 1); cm.isDoubleSided = true
            cube.materials = [cm]; scene.rootNode.addChildNode(SCNNode(geometry: cube))

            // radar floor grid (lines at z=0 / scene y=-1)
            for t in stride(from: -1.0, through: 1.0, by: 0.5) {
                for axis in 0..<2 {
                    let bar = SCNBox(width: axis==0 ? 2 : 0.006, height: 0.006, length: axis==0 ? 0.006 : 2, chamferRadius: 0)
                    let m = SCNMaterial(); m.diffuse.contents = NSColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 0.7)
                    m.emission.contents = NSColor(red: 0.1, green: 0.45, blue: 0.2, alpha: 1); bar.materials = [m]
                    let n = SCNNode(geometry: bar)
                    n.position = axis==0 ? SCNVector3(0, floorY, t) : SCNVector3(t, floorY, 0)
                    scene.rootNode.addChildNode(n)
                }
            }

            // radar SWEEP arm on the floor (rotates around the centre)
            let sweep = SCNNode(); sweep.position = SCNVector3(0, floorY + 0.006, 0)
            let arm = SCNBox(width: 0.9, height: 0.004, length: 0.02, chamferRadius: 0)
            let am = SCNMaterial(); am.diffuse.contents = NSColor(red:0.15,green:0.95,blue:0.35,alpha:0.55)
            am.emission.contents = NSColor(red:0.15,green:0.85,blue:0.3,alpha:1); am.writesToDepthBuffer = false
            arm.materials = [am]
            let armNode = SCNNode(geometry: arm); armNode.position = SCNVector3(0.45, 0, 0)
            sweep.addChildNode(armNode)
            sweep.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi*2, z: 0, duration: 3.5)))
            scene.rootNode.addChildNode(sweep)

            // node markers + labels
            for n in e.np3d {
                let sph = SCNSphere(radius: 0.06)
                sph.firstMaterial?.diffuse.contents = NSColor.systemBlue
                sph.firstMaterial?.emission.contents = NSColor.systemBlue
                let node = SCNNode(geometry: sph); node.position = pos(n.x, n.y, n.z)
                scene.rootNode.addChildNode(node)
                let t = SCNText(string: ".\(n.id)", extrusionDepth: 0.2)
                t.font = NSFont.boldSystemFont(ofSize: 2); t.firstMaterial?.diffuse.contents = NSColor.white
                let tn = SCNNode(geometry: t); tn.scale = SCNVector3(0.05, 0.05, 0.05)
                tn.position = SCNVector3(node.position.x + 0.08, node.position.y + 0.08, node.position.z)
                tn.constraints = [SCNBillboardConstraint()]; scene.rootNode.addChildNode(tn)
                nodeMarkers.append((n.id, node, tn))
            }

            // dim voxel "returns" pool
            let sx = CGFloat(2.0/Double(e.gx))*0.8, sy = CGFloat(2.0/Double(e.gz))*0.8, sz = CGFloat(2.0/Double(e.gy))*0.8
            for k in 0..<e.gz { for j in 0..<e.gy { for i in 0..<e.gx {
                let b = SCNBox(width: sx, height: sy, length: sz, chamferRadius: 0)
                let m = SCNMaterial(); m.diffuse.contents = NSColor.systemTeal
                m.isDoubleSided = true; m.writesToDepthBuffer = false; b.materials = [m]
                let node = SCNNode(geometry: b); node.opacity = 0
                node.position = pos((Double(i)+0.5)/Double(e.gx), (Double(j)+0.5)/Double(e.gy), (Double(k)+0.5)/Double(e.gz))
                voxNodes.append(node); scene.rootNode.addChildNode(node)
            }}}

            // TARGET blip (hidden until detected)
            let blip = SCNSphere(radius: 0.1)
            let bm = SCNMaterial(); bm.diffuse.contents = NSColor.systemRed; bm.emission.contents = NSColor.systemRed
            blip.materials = [bm]; targetNode.geometry = blip; targetNode.opacity = 0
            targetNode.runAction(.repeatForever(.sequence([.scale(to: 1.35, duration: 0.6), .scale(to: 0.85, duration: 0.6)])))
            scene.rootNode.addChildNode(targetNode)

            // drop-line to the floor
            let dl = SCNCylinder(radius: 0.012, height: 1)
            let dlm = SCNMaterial(); dlm.diffuse.contents = NSColor.systemOrange; dlm.emission.contents = NSColor.systemOrange
            dl.materials = [dlm]; dropLine.geometry = dl; dropLine.opacity = 0
            scene.rootNode.addChildNode(dropLine)

            // floor range ring
            let tor = SCNTorus(ringRadius: 0.18, pipeRadius: 0.012)
            let tm = SCNMaterial(); tm.diffuse.contents = NSColor.systemRed; tm.emission.contents = NSColor.systemRed
            tor.materials = [tm]; ring.geometry = tor; ring.opacity = 0
            ring.runAction(.repeatForever(.sequence([.scale(to: 1.6, duration: 1.0), .scale(to: 1.0, duration: 0.0)])))
            scene.rootNode.addChildNode(ring)

            // track pool
            for _ in 0..<24 {
                let s = SCNSphere(radius: 0.035)
                let m = SCNMaterial(); m.diffuse.contents = NSColor.systemYellow; m.emission.contents = NSColor.systemYellow
                s.materials = [m]; let n = SCNNode(geometry: s); n.opacity = 0
                trailNodes.append(n); scene.rootNode.addChildNode(n)
            }

            // camera
            let cam = SCNCamera(); cam.zNear = 0.01
            let camNode = SCNNode(); camNode.camera = cam
            camNode.position = SCNVector3(2.8, 2.2, 3.4)
            camNode.constraints = [SCNLookAtConstraint(target: scene.rootNode)]
            scene.rootNode.addChildNode(camNode)
        }

        func attach(_ v: SCNView) {
            v.pointOfView = scene.rootNode.childNodes.last(where: { $0.camera != nil })
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        }

        private func refresh() {
            // node markers follow the MEASURED (self-localized) positions
            for m in nodeMarkers {
                if let n = e.np3d.first(where: { $0.id == m.id }) {
                    let p = pos(n.x, n.y, n.z)
                    m.sphere.position = p
                    m.label.position = SCNVector3(p.x + 0.08, p.y + 0.08, p.z)
                }
            }
            // faint raw returns (context only) -- keep the extracted contact the star of the show
            let vox = e.vox
            for idx in voxNodes.indices where idx < vox.count {
                let val = min(1.0, Double(vox[idx]))
                voxNodes[idx].opacity = val < 0.55 ? 0 : CGFloat(0.03 + val*0.06)
            }
            // target contact
            if let t = e.target {
                let p = pos(t.x, t.y, t.z)
                targetNode.position = p; targetNode.opacity = 1
                // drop-line: from the blip down to the floor
                let h = CGFloat(p.y) - floorY
                dropLine.geometry = SCNCylinder(radius: 0.012, height: max(0.01, h))
                (dropLine.geometry as? SCNCylinder)?.firstMaterial?.emission.contents = NSColor.systemOrange
                dropLine.position = SCNVector3(p.x, floorY + h/2, p.z); dropLine.opacity = 0.9
                ring.position = SCNVector3(p.x, floorY + 0.01, p.z); ring.opacity = 0.9
            } else {
                targetNode.opacity = 0; dropLine.opacity = 0; ring.opacity = 0
            }
            // track
            let tr = e.trail
            for i in trailNodes.indices {
                if i < tr.count {
                    let c = tr[tr.count-1-i]
                    trailNodes[i].position = pos(c.x, c.y, c.z)
                    trailNodes[i].opacity = CGFloat(max(0, 0.6 - Double(i)*0.028))
                } else { trailNodes[i].opacity = 0 }
            }
        }
    }
}
