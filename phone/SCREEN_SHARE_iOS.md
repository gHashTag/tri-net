# iOS screen sharing — implementation plan (Broadcast Upload Extension)

Status: **NOT built** — deliberately deferred. iPhone screen-share of OTHER apps is only possible via a
Broadcast Upload Extension, which is a SEPARATE app-extension target + App Group + device provisioning. This
repo's iOS project must NOT be regenerated (breaks signing per phone CLAUDE.md), and none of it can be verified
headlessly (no device; broadcast extensions don't run real screen capture in the Simulator). So this is a
device-session feature. Everything needed is written out below so it can be finished quickly.

## Why not the easy path
`RPScreenRecorder.startCapture` (in-app ReplayKit) captures only the APP'S OWN window — useless for "share my
screen". Capturing the whole device (other apps) REQUIRES a Broadcast Upload Extension that iOS runs in a
separate process, started from the system broadcast picker (`RPSystemBroadcastPickerView`).

## Architecture (screen REPLACES camera, like Zoom)
Two processes, so they coordinate through an **App Group** shared container:

```
Main app (in a call)                         Broadcast Extension (separate process)
  on call start writes to App Group:           SampleHandler.processSampleBuffer(.video):
    screenSharePeerIPs = "ip1,ip2"               read peerIPs + key + active from App Group
    screenShareKey     = base64(sessionKey)      H264Encoder.encode(screen frame)
    screenShareActive  = true/false              seal with key -> UDP sendto each ip:7000
  while a broadcast is live: PAUSE the camera    (same wire format as the camera, so the peer's
  send (set a `screenSharing` flag that stops     decoder shows it as the remote video — no peer
  camera.onFrame -> transport)                    change needed)
```

Key points:
- **Screen and camera must not both send to :7000** — the peer's decoder would interleave two NAL streams into
  garbage. So the main app stops the camera send while the broadcast is live (screen replaces the tile).
- **Crypto:** the extension can't read the main app's in-memory ephemeral session key, so the main app writes
  it (base64) to the App Group on call start and clears it on call end. Acceptable for a LAN demo; if that key
  sharing is unwanted, add a separate screen-share port + the static conference key instead.
- **Fragmentation:** reuse the exact `[0xFA 0xFB seq idx total]+chunk` split from BSDTransport (screen frames
  are big). The extension needs its own copy of the frag + seal helpers (extensions can't link the app target).

## Steps
1. `phone/project.yml`: add a new target `TriNetBroadcast` (type `app-extension`,
   `com.apple.broadcast-services-upload`), with its own Info.plist (`NSExtensionPointIdentifier =
   com.apple.broadcast-services-upload`, `RPBroadcastProcessMode = RPBroadcastProcessModeSampleBuffer`) and an
   App Group entitlement `group.com.trinet.video`. Add the SAME App Group to the main app's entitlements.
   Regenerating the project is the blocker — do this in Xcode's UI on the device machine, or hand-add the
   target so the static file list / signing survives.
2. Extension `SampleHandler.swift` (skeleton below).
3. Main app: on call start write `screenSharePeerIPs/Key`; add a "Share screen" button using
   `RPSystemBroadcastPickerView` (the only way to start the picker); set `screenSharing` to pause camera send
   while `screenShareActive`.

## SampleHandler.swift (extension) — skeleton
```swift
import ReplayKit
import VideoToolbox

class SampleHandler: RPBroadcastSampleHandler {
    private let enc = H264Encoder()            // a COPY of the app's encoder (extensions can't link the app)
    private var sock: Int32 = -1
    private var peers: [sockaddr_in] = []
    private var key: SymmetricKey?
    private let group = UserDefaults(suiteName: "group.com.trinet.video")

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        sock = socket(AF_INET, SOCK_DGRAM, 0)
        if let b64 = group?.string(forKey: "screenShareKey"), let d = Data(base64Encoded: b64) {
            key = SymmetricKey(data: d)
        }
        let ips = (group?.string(forKey: "screenSharePeerIPs") ?? "").split(separator: ",").map(String.init)
        peers = ips.map { ip in
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET)
            a.sin_port = UInt16(7000).bigEndian; a.sin_addr.s_addr = inet_addr(ip); return a
        }
        enc.onFrame = { [weak self] nal, _ in self?.sendSealed(nal) }   // fragment+seal inside sendSealed
    }

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        enc.encode(pixelBuffer: pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    // sendSealed: split >1200B NALs into [0xFA 0xFB seq idx total]+chunk, ChaChaPoly.seal(chunk, key),
    // sendto each peer. (Copy the frag+seal from BSDTransport.)
    private func sendSealed(_ nal: Data) { /* … */ }
}
```

## Verification (device only)
- Rebuild both iPhones, start a call, tap "Share screen" -> the system picker -> pick TriNetBroadcast.
- The peer should see your whole screen replace your camera. Stop -> camera returns.
- Watch the main app log for `screenShareActive=true`, and the peer for `NAL #… FIRST FRAME DECODED` from the
  screen stream. Headless can't reach any of this.
