# WAVE W14: trios-chat UX + Deployment Automation

**After:** W13 (mesh convergence)
**Duration:** 1 week
**Goal:** Demoable product — open browser, see mesh, send message

---

## Deliverables

| # | What | Output |
|---|------|--------|
| 1 | Web UI on Zynq (nginx + WebSocket) | Browser at http://192.168.1.11/chat |
| 2 | Mesh status dashboard | Live neighbor map + ETX bars |
| 3 | Message send/receive | Text over mesh, encrypted |
| 4 | Auto-deploy tool | `tools/deploy` writes all SD cards, runs mesh |
| 5 | Demo video script | 3 boards, send photo, show convergence |

## Architecture

```
Browser (Mac/phone)
    │ HTTP/WebSocket
    ▼
nginx on Zynq ARM (port 80)
    │ Unix socket
    ▼
trios_meshd (mesh daemon, port 5000)
    │ UDP encrypted
    ▼
Other boards via mesh
```

## Key specs (new)

```
specs/chat_protocol.t27     — message framing (type, src, dst, body, timestamp)
specs/web_api.t27            — REST endpoints (/status, /send, /messages)
specs/mesh_dashboard.t27     — neighbor discovery + ETX display
```

phi^2 + phi^-2 = 3
