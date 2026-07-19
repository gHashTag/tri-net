import SwiftUI
import SceneKit

// 3D radio-tomographic view: renders the RTIEngine's voxel field as a semi-transparent volumetric
// point cloud you can orbit. The four boards sit at two heights, so a shadow is localized in SPACE
// (x, y AND z / floor), not just on a floor plan. Fed by the same UDP link packets as the 2D map.
struct RTI3DView: NSViewRepresentable {
    @ObservedObject var e: RTIEngine

    func makeCoordinator() -> Coord { Coord(e) }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = context.coordinator.scene
        v.allowsCameraControl = true          // orbit / zoom with the mouse
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
        private var timer: Timer?

        init(_ e: RTIEngine) { self.e = e; build() }

        // engine coords (x,y,z in [0,1]) -> centred SceneKit space, engine z is UP (SceneKit Y)
        private func pos(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
            SCNVector3((x-0.5)*2.0, (z-0.5)*2.0, (y-0.5)*2.0)
        }

        private func build() {
            // bounding cube (wireframe)
            let cube = SCNBox(width: 2, height: 2, length: 2, chamferRadius: 0)
            let cm = SCNMaterial(); cm.fillMode = .lines
            cm.diffuse.contents = NSColor(white: 0.35, alpha: 1); cm.isDoubleSided = true
            cube.materials = [cm]
            scene.rootNode.addChildNode(SCNNode(geometry: cube))

            // node markers + labels (the four boards)
            for n in e.np3d {
                let sph = SCNSphere(radius: 0.07)
                sph.firstMaterial?.diffuse.contents = NSColor.systemBlue
                sph.firstMaterial?.emission.contents = NSColor.systemBlue
                let node = SCNNode(geometry: sph); node.position = pos(n.x, n.y, n.z)
                scene.rootNode.addChildNode(node)
                let t = SCNText(string: ".\(n.id)", extrusionDepth: 0.2)
                t.font = NSFont.boldSystemFont(ofSize: 2); t.firstMaterial?.diffuse.contents = NSColor.white
                let tn = SCNNode(geometry: t); tn.scale = SCNVector3(0.06, 0.06, 0.06)
                tn.position = SCNVector3(node.position.x + 0.09, node.position.y + 0.09, node.position.z)
                tn.constraints = [SCNBillboardConstraint()]      // always face the camera
                scene.rootNode.addChildNode(tn)
            }

            // voxel pool: one small box per voxel, opacity/colour driven by the field
            let sx = CGFloat(2.0/Double(e.gx))*0.82
            let sy = CGFloat(2.0/Double(e.gz))*0.82
            let sz = CGFloat(2.0/Double(e.gy))*0.82
            for k in 0..<e.gz { for j in 0..<e.gy { for i in 0..<e.gx {
                let b = SCNBox(width: sx, height: sy, length: sz, chamferRadius: 0)
                let m = SCNMaterial(); m.diffuse.contents = NSColor.systemBlue
                m.transparencyMode = .dualLayer; m.isDoubleSided = true; m.writesToDepthBuffer = false
                b.materials = [m]
                let node = SCNNode(geometry: b)
                node.position = pos((Double(i)+0.5)/Double(e.gx), (Double(j)+0.5)/Double(e.gy), (Double(k)+0.5)/Double(e.gz))
                node.opacity = 0
                voxNodes.append(node); scene.rootNode.addChildNode(node)
            }}}

            // camera
            let cam = SCNCamera(); cam.zNear = 0.01
            let camNode = SCNNode(); camNode.camera = cam
            camNode.position = SCNVector3(2.6, 2.0, 3.2)
            camNode.constraints = [SCNLookAtConstraint(target: scene.rootNode)]
            scene.rootNode.addChildNode(camNode)
        }

        func attach(_ v: SCNView) {
            v.pointOfView = scene.rootNode.childNodes.last
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.refresh() }
        }

        private func refresh() {
            let vox = e.vox
            for idx in voxNodes.indices where idx < vox.count {
                let val = min(1.0, Double(vox[idx]))
                let node = voxNodes[idx]
                if val < 0.2 { node.opacity = 0; continue }
                node.opacity = CGFloat(0.12 + val*0.55)
                let c = Coord.heat(val)
                node.geometry?.firstMaterial?.diffuse.contents = c
                node.geometry?.firstMaterial?.emission.contents = c
            }
        }

        // blue -> cyan -> green -> yellow -> red
        static func heat(_ v: Double) -> NSColor {
            let t = max(0, min(1, v))
            if t < 0.25 { return NSColor(red: 0.1, green: 0.3+t*2.0, blue: 0.95, alpha: 1) }
            if t < 0.5  { return NSColor(red: 0.1, green: 0.85, blue: 0.9-(t-0.25)*3.0, alpha: 1) }
            if t < 0.75 { return NSColor(red: 0.1+(t-0.5)*3.2, green: 0.9, blue: 0.1, alpha: 1) }
            return NSColor(red: 0.95, green: 0.9-(t-0.75)*3.2, blue: 0.1, alpha: 1)
        }
    }
}
