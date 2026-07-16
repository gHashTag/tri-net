# TRI-NET — Brand Book & UI Kit

The visual system for TRI-NET's apps (macOS Monitor + iOS). A near-monochrome,
editorial language inspired by xAI/Grok: restraint, hairlines instead of
shadows, fully-rounded pills as the signature shape, and one high-contrast
white fill for the primary action.

The code lives in `desktop/DesignSystem.swift` (the `DS` enum + components).
Every tab and the header draw from it — one vocabulary, applied everywhere.

---

## 1. Principles

1. **Monochrome first.** Black surfaces, white ink, grayscale in between. Color
   appears only as a *signal* (green = live, red = stop) — never as decoration.
2. **Hairlines, not shadows.** Depth is a 1px ring at 10–20% white. No blur, no
   drop shadows on chrome.
3. **The pill is the shape.** Every button, tab, chip, and status uses a fully
   rounded capsule. One filled white pill per view is the primary action.
4. **Type carries hierarchy.** Large, tight display headings; a sans face for UI
   copy; a mono face for anything technical (IPs, counters, IDs, status).
5. **Restraint.** 1–3 emphasized elements per view. Space does the work.

---

## 2. Color tokens

| Token | Value | Use |
|-------|-------|-----|
| `ink` | `#0A0A0A` | App base / canvas |
| `surface` | `#151515` | Panels, cards, video letterbox |
| `surfaceHi` | `#1F1F1F` | Hover / raised |
| `hairline` | `white @ 10%` | Default ring / divider |
| `hairlineStrong` | `white @ 20%` | Emphasized ring, outline pills |
| `text` | `white @ 95%` | Primary text |
| `dim` | `white @ 55%` | Secondary text |
| `faint` | `white @ 32%` | Labels, metadata |
| `fill` | `#FFFFFF` | The one filled CTA pill |
| `onFill` | `#000000` | Text on the white fill |
| `live` | `#4CD972` | Connected / active dot only |
| `danger` | `#F25959` | End call / stop only |

---

## 3. Typography

| Role | Face | Size / weight |
|------|------|---------------|
| Display | SF Rounded / system | 26–28 pt, semibold, tracking −0.5 |
| Title | system | 14–15 pt, semibold |
| Body / UI | system | 12–13 pt, regular–medium |
| Data / mono | SF Mono | 9–14 pt — IPs, counters, status, IDs |
| Label | SF Mono | 10 pt, medium, uppercase, tracking +1 |

Rule of thumb: **if it's a number or an address, it's mono.** If it's a word a
human reads, it's the sans face.

---

## 4. Components (`DesignSystem.swift`)

| Component | What it is |
|-----------|-----------|
| `PillButton(filled:)` | Signature action pill. `filled` = the one white CTA; else a hairline-outline pill. |
| `TabPill` | Primary nav tab. Active = subtle fill + hairline; inactive = dim label. |
| `IconPill` | Round 40pt icon control with a hairline ring; `active` tints it. |
| `StatusTag(live:)` | Dot + uppercase mono label in a hairline capsule. |
| `SectionLabel` | Faint uppercase mono section header. |
| `Hairline` | 1px divider at 10% white. |
| `.dsCard()` | Charcoal surface + hairline ring, radius 12 (no shadow). |

Metrics: card radius **12**, pills fully rounded, standard pad **14**.

---

## 5. Layout & the header

- The header is one row: the **`TRI-NET`** wordmark, then the tab pills
  (`Network` · `RTI Heatmap` · `Video Call`), closed by a bottom hairline.
- Every tab uses the same `DS.ink` canvas and the same component set, so
  switching tabs never changes the visual language — only the content.
- Toolbar actions (Scan / Monitor / Devices) sit top-right, monochrome.

---

## 6. Do / Don't

**Do** — one white pill CTA per screen · mono for all data · hairline rings ·
green/red only for live/stop signals · generous space.

**Don't** — colored accents for style · drop shadows or glassy blur on chrome ·
more than one filled pill per view · mixing corner radii · sans for numbers.

---

*Anchor: φ² + φ⁻² = 3 · TRINITY*
