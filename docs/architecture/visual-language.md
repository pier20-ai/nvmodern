# nvModern visual language

This document defines the visual direction for nvModern's shell UI — everything outside the note body. The note body is rendered in a WebView and has its own type/color system; that's out of scope.

The goal is to make the app feel like one thing. Today's "custom + default AppKit" mix is the problem this doc exists to solve.

---

## 1. Philosophy

- **Quiet.** The note is the product; chrome serves it. Nothing in the shell should compete with the content.
- **Native-feeling.** This is a macOS app. It should feel like macOS, not like a cross-platform web app or a Material-Design surface.
- **Keyboard-first.** Every surface has a visible keyboard affordance. Discoverability through visible shortcuts, not tutorials.
- **Dense without being crowded.** Information-rich layouts, not whitespace-heavy marketing pages. But every element has room to breathe.
- **Reference points.** Takes after Linear, Arc, Craft, Things 3. Explicitly *not* after Notion, Obsidian, or any web-first note app.

If a design choice can be argued either way, the one that makes the shell quieter wins.

---

## 2. Typography

One type family for UI, one for monospace, six sizes, three weights. That's it.

| Role | Family | Size | Weight |
|---|---|---|---|
| Caption (badges, shortcut hints) | SF Pro Text | 11 | regular |
| Secondary (metadata, subtle labels) | SF Pro Text | 12 | regular |
| Body (list rows, buttons, inputs) | SF Pro Text | 13 | regular / medium |
| Emphasis (selected row, section title) | SF Pro Text | 13 | semibold |
| Heading (launchpad section, dashboard title) | SF Pro Text | 15 | semibold |
| Display (folder dashboard title, empty-state) | SF Pro Display | 22 | semibold |
| Mono (paths, code, shortcut glyphs) | SF Mono | 12 | regular |

Rules:

- never use more than three sizes in a single view
- never use italic for emphasis — use weight or color instead
- letter-spacing is system default; do not tighten

---

## 3. Color

Dark-first. Light mode follows mechanically (invert the luminance ramp, keep the accent hues).

### 3.1 Surface ramp (dark)

Near-black base, elevation via small opacity bumps. Never pure black.

| Token | Value | Use |
|---|---|---|
| `surface/base` | `#0D0D10` | window background |
| `surface/raised` | `#16161B` | palette body, launchpad |
| `surface/overlay` | `#1E1E24` | list row hover, tab hover |
| `surface/selected` | `#2A2A33` | selected list row, active tab |

### 3.2 Text (dark)

| Token | Value | Use |
|---|---|---|
| `text/primary` | `#F2F2F5` | body text, selected item |
| `text/secondary` | `#A0A0A8` | metadata, section labels |
| `text/tertiary` | `#606068` | disabled, subtle hints |

### 3.3 Accents (shared, mode + semantic)

Muted, cool-family colors. Pick the 500-weight equivalent, not the 400. Applied as fills, not text — text-on-accent is always white.

| Token | Value | Use |
|---|---|---|
| `accent/nav` | `#5A8DEE` | Quick Find, links, focus ring |
| `accent/intent` | `#E0A64B` | Actions, warnings |
| `accent/search` | `#4FB0A6` | Content Search |
| `accent/destructive` | `#E0584B` | delete, irreversible actions |
| `accent/success` | `#5CB870` | confirmation, completion |

Mode accents are named after their role, not their color, so a theme swap is a token remap.

### 3.4 Light mode (derived)

| Token | Value |
|---|---|
| `surface/base` | `#FAFAFB` |
| `surface/raised` | `#FFFFFF` |
| `surface/overlay` | `#F0F0F2` |
| `surface/selected` | `#E4E4E8` |
| `text/primary` | `#1A1A1F` |
| `text/secondary` | `#606068` |
| `text/tertiary` | `#A0A0A8` |

Accents are the same in both modes.

---

## 4. Spacing

4/8 rhythm, capped at seven values. Anything outside this list is a mistake.

| Token | Value |
|---|---|
| `space/1` | 2pt |
| `space/2` | 4pt |
| `space/3` | 8pt |
| `space/4` | 12pt |
| `space/5` | 16pt |
| `space/6` | 24pt |
| `space/7` | 32pt |

Common applications:

- list row vertical padding: `space/3` (8)
- list row horizontal padding: `space/4` (12)
- card / panel padding: `space/4` (12)
- section gap: `space/6` (24)
- inline icon-to-label gap: `space/2` (4)

---

## 5. Corner radii

| Token | Value | Use |
|---|---|---|
| `radius/input` | 4 | inputs, list rows, small chips |
| `radius/card` | 8 | palette body, action tiles, cards |
| `radius/pill` | 999 | fully rounded badges and compact controls |
| `radius/window` | system | sheets, alerts (don't override) |

---

## 6. Elevation

**Flat by default.** Inside a palette or launchpad, list rows have zero elevation — selection is a background fill, never a shadow.

**One floating level** — the palette itself.

| Token | Value |
|---|---|
| `elevation/flat` | none |
| `elevation/floating` | y=8, blur=32, rgba(0,0,0,0.25) |

No stacked shadows. If you're reaching for a second elevation level, the layout is wrong.

---

## 7. Materials

- **Vibrancy** — reserve for the window titlebar/toolbar only. Overusing vibrancy is the fastest way to make a macOS app look cheap.
- **Solid** — palette body, launchpad, context ribbon. Solid `surface/raised` with opacity-step elevation beats vibrancy for readability at 13pt.
- **Blur** — avoid. Blur + text = hard to read and fingerprints the app as "web tech trying to look native."

---

## 8. Icons

**SF Symbols only**, at `.medium` weight, sized to match 13pt type (about 14pt glyph box). No Font Awesome, no emoji-as-icon, no mixed icon libraries.

For glyphs SF doesn't have (breadcrumb separator `›`, mode dot `●`, etc.), draw custom SVGs matched to SF's optical weight. Document them in Appendix B. If the custom set grows past 6 glyphs, that's a signal to rethink.

Mode icons:

| Mode | Symbol | Tint |
|---|---|---|
| Quick Find | `magnifyingglass` | `accent/nav` |
| Actions | `bolt.fill` | `accent/intent` |
| Content Search | `doc.text.magnifyingglass` | `accent/search` |

---

## 9. Motion

Short, eager, no overshoot. This is a writing tool, not a toy.

| Transition | Duration | Easing |
|---|---|---|
| Palette bloom (idle → active) | 180ms | `cubic-bezier(0.2, 0, 0, 1)` |
| Palette collapse (active → idle) | 140ms | `cubic-bezier(0.4, 0, 1, 1)` |
| Segment swap (mode change) | 120ms | crossfade, linear |
| Breadcrumb `…` expand | 150ms | `cubic-bezier(0.2, 0, 0, 1)` |
| List row selection | 80ms | linear fill |
| Tab switch | 60ms | opacity only, no slide |

Rules:

- no springs that overshoot
- no staggered / cascading animations on list rows
- no attention-drawing decorative motion (pulses, shimmer, etc.)
- prefer opacity + small position deltas over scale

---

## 10. Component catalog

Each component specs: mockup, tokens used, behavior notes. Add new components here as surfaces ship; don't speculate.

### 10.1 Searchbox — idle

```text
┌──────────────────────────────────────────────────────────────────────────┐
│  🔎  10-Workspaces  ›  …  ›  12-Claude-Book  ›  01_foundations  📌 ↗ ⟳ ⌄ │
└──────────────────────────────────────────────────────────────────────────┘
```

- surface: `surface/raised`
- text: `text/primary` for crumbs, `text/tertiary` for separators `›`
- radius: `radius/pill`
- height: 32pt
- horizontal padding: `space/4`
- icon-to-crumb gap: `space/3`

### 10.2 Searchbox — active (palette bloomed)

```text
╭──────────────────────────────────────────────────────────────────────────╮
│  🔎  query|                        [●Quick Find] [ Actions ] [ Content ] │
│ ·························································· ··············│
│  Section header                                                          │
│   > Selected row with accent bar                  nearby · 12-Claude     │
│     Unselected row                                recent                 │
│                                                                          │
│  [⏎ open]  [⌘⏎ new tab]                                                  │
╰──────────────────────────────────────────────────────────────────────────╯
```

- outer radius: 8 top, 8 bottom; straight sides
- internal divider: 1px `text/tertiary` at 30% opacity
- elevation: `elevation/floating`
- max height: 60% of tab height; overflow scrolls inside the results area
- footer row with keyboard hints: `text/tertiary`, 11pt caption

### 10.3 Palette list row

```text
 ┌─────────────────────────────────────────────────────────────────────┐
 │ > 03_black_scholes.md                       12-Claude-Book · nearby │
 │   04_why_bs_breaks.md                       12-Claude-Book · nearby │
 │   options-black-scholes-notes.md            10-Study-Notes · recent │
 └─────────────────────────────────────────────────────────────────────┘
```

- row height: 32pt
- horizontal padding: `space/4`
- selected row: background `surface/selected`, 3pt accent bar on the left edge in the current mode's color
- unselected row: transparent, hover → `surface/overlay`
- label: `text/primary` 13pt
- metadata (right-aligned): `text/secondary` 12pt
- badge text (`nearby`, `recent`): `text/tertiary` 11pt caption

### 10.4 Section header

```text
 Nearby
 ──────
 > 03_black_scholes.md
```

- label: `text/tertiary` 11pt semibold uppercase
- underline: none (the type alone separates)
- top padding: `space/3`, bottom padding: `space/2`

### 10.5 Segmented control

```text
  [●Quick Find] [ Actions ] [ Content ]
```

- outer radius: `radius/pill`
- segment radius: `radius/pill` (when filled)
- height: 24pt
- segment padding: `space/3` horizontal
- current segment: filled with current mode's accent, text `#FFFFFF`
- other segments: transparent fill, text `text/secondary`, border 1px `text/tertiary` at 20%
- hover on inactive segment: background `surface/overlay`
- tooltip on hover: shortcut hint (`⌘K`, `⌘⇧K`, `⌘⇧F`)

### 10.6 Context button

Small icon buttons on the right side of the idle searchbox (📌 ↗ ⟳ ⇱ ⌄):

- size: 24×24pt
- icon: 14pt SF Symbol, `text/secondary`
- hover: background `surface/overlay`, icon → `text/primary`
- pressed: background `surface/selected`
- gap between buttons: `space/1` (2)

### 10.7 Breadcrumb crumb

```text
 10-Workspaces  ›  12-Claude-Book  ›  01_foundations
```

- folder crumb: `text/primary`, hover → accent/nav
- separator `›`: `text/tertiary`, no hover state
- note crumb (last): `text/primary` semibold, no hover state
- ellipsis `…`: `text/tertiary`, hover → accent/nav, click expands
- horizontal padding per crumb: `space/2`

### 10.8 Launchpad action tile

```text
 ┌────────────────────────────┐
 │  +  New note here          │
 │     in 12-Claude-Book      │
 └────────────────────────────┘
```

- surface: `surface/raised`
- hover: `surface/overlay`
- radius: `radius/card` (8)
- padding: `space/4`
- title: `text/primary` 13pt medium
- subtitle: `text/secondary` 12pt
- icon: 16pt SF Symbol, `text/secondary`
- width: flexible, min 180pt, max 280pt
- grid gap: `space/3`

### 10.9 Tab

```text
┌──────────┐┌──────────┐┌──────────┐
│ manu.md  ││ weekly.md││[01_foun…]│
└──────────┘└──────────┘└──────────┘
```

- active tab: `surface/raised`, text `text/primary`
- inactive tab: `surface/base`, text `text/secondary`
- hover inactive: `surface/overlay`
- height: 32pt
- padding: `space/4` horizontal
- close button: appears on hover, 14pt SF `xmark`
- split-inactive (other split pane's active tab): same as active but with `text/secondary` label

### 10.10 Miller column cell

```text
 │ 10-Workspaces      › │
 │ 20-Records         › │
 │ 30-Assets          › │
```

- cell height: 28pt
- horizontal padding: `space/3`
- selected cell: `surface/selected`, text `text/primary`
- unselected: transparent, text `text/primary`
- hover: `surface/overlay`
- chevron `›` at right for folders with children, `text/tertiary`
- column width: fixed 200pt default, user-resizable

### 10.11 Folder dashboard metric row

```text
 · 3 stubs under 20 words                                       [show]
 · 5 drafts (#draft), oldest 38 days                            [show]
 · 12 open `- [ ]` items across 4 notes                         [show]
```

- bullet `·`: `text/tertiary`
- label: `text/primary` 13pt
- `[show]` / `[fix]` button: secondary button style, right-aligned
- row vertical padding: `space/3`
- no dividers between rows — spacing does the work

---

## 11. Anti-goals

- **No gradients** anywhere, except possibly a single 2% luminance gradient on the active tab to separate it from the titlebar
- **No decorative illustrations**, no empty-state art, no mascot, no welcome graphics
- **No Material Design / Fluent / web-app aesthetic** — no Roboto, no Material ripples, no floating action buttons, no bottom sheets
- **No attention-drawing animations** — no shimmer, no pulse, no spring overshoot
- **No typography flourishes** — no display fonts outside the single `Display` size, no italic for emphasis, no letter-spacing tweaks
- **No stacked shadows** — one elevation level exists; if you need another, the layout is wrong
- **No vibrancy inside content areas** — titlebar only

If a proposed design choice appears on this list, the answer is no.

---

## Appendix A — full token reference

```swift
// Surfaces (dark)
let surfaceBase      = Color(hex: "#0D0D10")
let surfaceRaised    = Color(hex: "#16161B")
let surfaceOverlay   = Color(hex: "#1E1E24")
let surfaceSelected  = Color(hex: "#2A2A33")

// Text (dark)
let textPrimary      = Color(hex: "#F2F2F5")
let textSecondary    = Color(hex: "#A0A0A8")
let textTertiary     = Color(hex: "#606068")

// Accents
let accentNav         = Color(hex: "#5A8DEE")
let accentIntent      = Color(hex: "#E0A64B")
let accentSearch      = Color(hex: "#4FB0A6")
let accentDestructive = Color(hex: "#E0584B")
let accentSuccess     = Color(hex: "#5CB870")

// Spacing
let space1 = 2.0; let space2 = 4.0; let space3 = 8.0
let space4 = 12.0; let space5 = 16.0; let space6 = 24.0; let space7 = 32.0

// Radii
let radiusInput = 4.0
let radiusCard  = 8.0
let radiusPill  = 999.0

// Elevation
let elevationFloating = NSShadow(offset: (0, 8), blur: 32, color: .black.opacity(0.25))

// Motion
let motionBloom    = (duration: 0.18, easing: .cubicBezier(0.2, 0, 0, 1))
let motionCollapse = (duration: 0.14, easing: .cubicBezier(0.4, 0, 1, 1))
let motionSwap     = (duration: 0.12, easing: .linear)
```

---

## Appendix B — custom glyphs

Document any glyph here that isn't an SF Symbol. Keep this list under 6; if it grows, rethink.

| Glyph | Use | Notes |
|---|---|---|
| `›` | breadcrumb separator | U+203A, `text/tertiary`, no hover |
| `…` | breadcrumb ellipsis | U+2026, `text/tertiary`, hover → `accent/nav` |

Current custom-glyph count: 2. Budget: 6.
