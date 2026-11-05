# A Modern Notational Velocity

## The Problem

Notational Velocity was, and remains, the best note-taking interface ever designed. One bar. One list. One editor. You typed, and the app responded — searching and creating were the same action. It was so fast and so light that you actually used it. That was its genius.

But NV had a fatal flaw: it couldn't scale. A hundred notes in a flat list was fine. A thousand was chaos. You couldn't see what you had. You couldn't organize what you'd collected. You'd create duplicates because the list was too dense to scan. NV optimized so heavily for *entry* that it abandoned *management* entirely.

The successors — Obsidian, Notion, Roam — went the other direction. They built elaborate management systems: nested folders, databases, backlinks, canvases, templates. The filing was excellent. The capture was terrible. Every new note demanded decisions: which folder? which template? what properties? The weight of the system discouraged the very act it was meant to support — writing things down.

Roam got closest to the right balance. Its `[[wiki links]]` and `((block references))` were search-and-create in spirit, inheriting NV's core insight. But Roam encouraged only atomic notes and made anything longer than a paragraph feel unnatural. And like NV, it had no hierarchy — just a graph that became unnavigable at scale.

The question: **can we build something with NV's speed and Obsidian's structure, without inheriting either's failure mode?**

The answer is yes, but it requires rethinking what "organization" means. Not as something the user does. As something that *happens* — with the user's guidance, but not their labor.

---

## Design Philosophy

Three principles govern every decision in this app:

### 1. Capture must be decision-free

The unified search/create bar is sacred. You never choose *where* a note goes at the moment of creation. You type, you write, you're done. This is the lesson of NV and Roam: the apps people actually use are the ones that don't make you think before you write.

### 2. Organization must happen, but not by you

There is a critical distinction between a **filing system** and a **filing decision**. NV eliminated both. Obsidian requires both. We want the system without the decision.

The user creates the organizational structure — their tree of folders, their mental model of how they think about their world. The system handles the act of filing into that structure, suggesting where each note belongs based on its content and context. The user accepts, refines, or overrides — but they never start from a blank "choose a folder" dialog.

### 3. The system is a garden, not a machine

Note systems are like gardens. People enjoy tending them — when the tending is rewarding. If the system is too automated, there's nothing to tend. If it's too manual, the tending becomes labor. The sweet spot: the system surfaces what needs attention, and hands you the shears.

This means the intelligence layer *suggests* but never *acts*. It says "these two notes look like duplicates" and offers a merge button. It says "this folder has 40 notes, maybe split it." It never reorganizes without permission. The user is the gardener. The system is the assistant who knows where the weeds are.

---

## Architecture: Two Layers

The app maintains two independent structural layers that serve different purposes:

### The Tree (Ontology)

A folder hierarchy, created and maintained by the user. It maps directly to the filesystem. This is the user's mental model: "this is how I think about my world."

The tree answers the question: **where do I *want* to find this?**

It represents human intent — deliberate categorization that reflects how the user organizes their thinking. A folder called "Q3 Planning" exists because the user decided that Q3 planning is a meaningful category in their life, not because an algorithm clustered some notes together.

### The Graph (Semantics)

A network of relationships between notes, generated automatically from content similarity, co-references, and backlinks. Dense, emergent, non-hierarchical.

The graph answers the question: **what is this *related* to?**

It represents content reality — how knowledge actually connects regardless of where the user filed it. A note about a meeting with James is filed under "Q3 Planning" (tree) but is also connected to "James 1:1 Notes" and "Mobile Team OKRs" (graph).

### Why both?

These layers aren't redundant. They operate at different levels:

- The tree is **stable** (folders don't change often) and **intentional** (the user created them). It's good for browsing and orientation.
- The graph is **dynamic** (new links emerge as notes are added) and **emergent** (no one creates the relationships). It's good for discovery and lateral thinking.

Obsidian has both but treats the graph as primary (the graph view is a headline feature). We treat the tree as primary for navigation and the graph as a secondary enrichment layer that surfaces connections the tree can't capture.

---

## The Interface: A Three-Pane Vertical Stack

The UI is a three-pane vertical stack. From top to bottom:

```
┌─────────────────────────────────────────────────────┐
│  Tab 1  │  Tab 2  │  +                              │  TABS
├─────────────────────────────────────────────────────┤
│  🔍 Search / Create bar                              │  BAR
├─────────────────────────────────────────────────────┤
│                                                     │
│  THE SPACE (dynamic, changes based on bar state)    │  SPACE
│                                                     │
├─────────────────────────────────────────────────────┤
│                                                     │
│                                                     │
│  EDITOR (the active note)                           │  EDITOR
│                                                     │
│                                                     │
│                                                     │
└─────────────────────────────────────────────────────┘
```

This layout is not a side-by-side split (Obsidian), not an overlay system (Cmd-K/Cmd-P), but a vertical stack where each band has a clear role:

- **Tabs** — Chrome-style, above the bar. Each tab owns its own state.
- **Bar** — Always visible. The universal controller. Everything starts here.
- **Space** — The dynamic navigation layer. Shows different things based on what the bar is doing.
- **Editor** — Always shows the active note. This is where you write.

The critical property: **the bar drives the space.** Type something, the space responds. Clear the bar, the space changes. There are no mode switches, no navigation events, no "going somewhere." Just the bar and the screen reacting to it.

### Why vertical, not horizontal?

A horizontal split (sidebar + editor) gives equal weight to navigation and editing. It says "you'll want the tree visible at all times." That's Obsidian's worldview — organization-first.

The vertical stack says: "writing is primary, but your knowledge structure is available as context." The editor dominates the screen. The space sits above it as a *collapsible* orientation layer. Pull the divider up and it's just the bar and the editor — pure NV. Pull it down when you need to browse. The tree is there when you want it, gone when you don't.

---

## The Bar

The search/create bar is the heart of the app. It inherits NV's core innovation — searching and creating are the same action — and extends it with filing intelligence.

### How it works

You type in the bar. The system does two things simultaneously:

1. **Searches** existing notes by title and content (semantic, not just substring)
2. **Suggests** a tree location for a new note if you choose to create one

### Filing inference

There is no explicit filing syntax. The BERT model infers the best tree location from the note's title and content alone.

When you type "Meeting with James — discussed Q3 roadmap, he wants to prioritize mobile," the model recognizes "Q3," "roadmap," and "mobile" as high-signal tokens that match the Q3 Planning folder — because it's been trained on the user's collection and knows what lives where.

If the user happens to include a folder-like phrase in their title, BERT picks up on it naturally — not because of parsing rules, but because folder names are high-signal tokens in the model's vocabulary. "Quick thought about the budget" naturally gravitates toward the Budget folder. No syntax needed.

The filing suggestion is always a default. The user can override it by arrowing to a different search result (filing as a sibling of that note's location) or by navigating the Miller columns to choose a location manually. But the common path is: type, see the suggestion, press Enter. The model did the filing.

### Transient vs. active notes

When the user arrows through search results, the editor shows a **transient preview** of the selected note — visually distinct from the active note (subtle indicator: "previewing · ESC to return · ENTER to open").

- **ESC** — editor snaps back to the active note
- **ENTER** — the previewed note becomes the active note in this tab
- **Cmd+ENTER** — opens in a new tab, preserving the current active note

---

## The Space

The space is the horizontal band between the bar and the editor. Its content changes based on what the bar is doing.

### When the bar is empty: Miller Columns

The space shows Miller columns — the macOS Finder's column-view navigation. Each column is a level of the tree. Click a folder to see its children in the next column. Click a note to preview it in the editor.

```
├────────────┬────────────┬───────────────────────────┤
│ ▪ Work     │ ▪ Q3 Plan. │ ▪ Q3 Roadmap Priorities  │
│ ▪ Personal │ ▪ People   │ ▪ Meeting w/ James    ◀  │
│ ▪ Reading  │ ▪ Budget   │ ▪ Sprint Planning        │
│            │            │ ▪ 📎 Brief.pdf           │
├────────────┴────────────┴───────────────────────────┤
```

This solves NV's visibility problem. You see multiple levels of your tree simultaneously. You always know where you are. Navigation is spatial — click to drill in, breadcrumb or swipe to go back. No sidebar eating horizontal space.

Miller columns are deeply Mac-native (Finder, Mail, many Apple apps). They're the natural fit for a wide, short horizontal band. And they handle the tree structure without any new metaphors.

Folders, notes, and proxy notes all appear as items in the columns. Proxy notes show a type indicator (📎 for PDF, 🖼 for images, etc.) to distinguish them from text notes.

### When the bar has text: Search Results

The Miller columns are replaced by a flat, ranked list of matching notes:

```
├─────────────────────────────────────────────────────┤
│ ▸ Q3 Roadmap Priorities    Work › Q3 Plan.    87%  │
│ ▸ James 1:1 Notes          Work › People      72%  │
│ ▸ Mobile Team OKRs         Work › Q3 Plan.    61%  │
│ + Create "james q3 mobile"  📍 Work › Q3 Plan.     │
├─────────────────────────────────────────────────────┤
```

Each result shows its **tree path** as a breadcrumb. You see where things live without needing a sidebar. At the bottom: the "Create" option with the BERT-suggested tree location.

Arrow keys move through results. The editor shows transient previews. Enter commits. This is NV's original interaction model, enhanced with tree awareness and semantic search.

The transition between Miller columns and search results is seamless — driven entirely by whether the bar has text.

---

## The Editor

The editor always shows the active note. It's a full-featured text editor for Markdown (or whatever format the user prefers). But it has two special modes that reflect the app's structural model:

### Note view (default)

The active note's content, editable. Below the content, garden suggestions surface maintenance hints specific to this note: "Similar to Q3 Mobile Plan — merge?", "This note has been in Inbox for 3 days — file?", etc. Actionable and dismissible.

Graph links (related notes, backlinks) are maintained by the system as a data layer but are **not surfaced in the UI initially**. The right way to display note relationships is an open design question — existing approaches (Roam's backlink panel, Obsidian's graph view) have not proven useful in practice. The graph data is there; the UI for it will be designed after using the app and discovering what relationship information is actually valuable during writing and browsing.

### Folder-as-outline view

When the user selects a folder (in Miller columns or search), the editor shows the folder as a Roam-style outline:

```
│  # Q3 Planning                                      │
│  Focus areas for this quarter.                      │
│                                                     │
│  ▸ Q3 Roadmap Priorities                            │
│    Mobile is top priority for H2. Focus areas...    │
│                                                     │
│  ▸ Meeting with James                               │
│    Discussed Q3 roadmap. He wants to prioritize...  │
│                                                     │
│  ▸ Sprint Planning                                  │
│    Agreed on 2-week cycles starting Sept 1...       │
│                                                     │
│  🌱 "Q3 Roadmap" ↔ "Meeting w/ James": 87%         │
│     similar. [Merge] [Dismiss]                      │
```

The folder itself can have prose — a summary, a table of contents, contextual notes about the category. Below the prose, each child note appears as a collapsible outline node showing the first few lines or a transclusion.

This works up to 2 levels deep: a folder shows its immediate children, and subfolder children are nested within. Dragging items reorders or refiles.

The outline view is where garden tending happens most naturally. You see everything in a category at a glance. Duplicates are obvious. Misplaced notes stand out. The garden suggestions appear right where you can act on them.

#### How notes appear in the outline

Each note renders as a **title line** (bold, styled distinctly) followed by a **body preview** (lighter, truncated). There is no separate title field — the title is the first line of the node.

```
▸ Meeting with James
  Discussed Q3 roadmap, he wants to prioritize
  mobile for H2...

▸ Q3 Roadmap Priorities
  Mobile is top priority. Focus areas:
  1. Replatform native apps...
```

On the filesystem, "Meeting with James" is the filename. Everything below is the file content. In the outline, they look like one continuous text block with a styled first line. Click the disclosure triangle to expand a node and see its full content, editable in place.

#### Creating notes from the outline

**Cmd+Enter** on any note creates a new sibling directly below it:

```
▸ Meeting with James
  Discussed Q3 roadmap, he wants to prioritize...

▾ |
  ← cursor here, in the title position (bold)

▸ Sprint Planning
  Agreed on 2-week cycles...
```

**Step 1: Type the title.** The cursor is in the bold title zone. Type "Budget review with Sarah."

**Step 2: Press Enter.** The cursor moves to the body zone. The file `Budget review with Sarah.md` is created on disk at this moment, as a sibling in the same folder. The node is now expanded with an empty body, ready for writing.

**Or skip the body.** After typing the title, press Cmd+Enter again to create another sibling immediately. The previous note exists with a title and empty body — fill it in later. This lets you rapidly scaffold an outline:

```
▸ Budget review with Sarah
  
▸ Hiring plan for mobile team
  
▸ Q3 launch timeline|
  
```

Three Cmd+Enters, three notes created, named, and placed — all without leaving the outline.

**Editing titles.** Click the bold first line of any note. It becomes editable. Change the text, and the file is renamed on disk. Same gesture as editing any other text.

**Why this works:** Cmd+Enter as the creation shortcut adds just enough friction to imply intention — you don't create notes by accident. The title-first flow means every note gets a real name at birth, avoiding the "Untitled Note #47" problem. And the interaction feels like Roam (inline outline editing) while preserving the filesystem-backed model (notes are files with names).

---

## Proxy Notes

Real-world knowledge bases aren't just Markdown files. They contain PDFs, Word documents, images, spreadsheets, presentations. Most note apps ignore these or treat them as attachments. We treat them as first-class citizens.

A **proxy note** is a note-like entity that represents a non-Markdown file in the knowledge base. It appears everywhere a regular note appears — in Miller columns, in search results, in folder outlines — with a type indicator to distinguish it visually.

Clicking a proxy note shows a detail view in the editor:

- A preview of the file (PDF rendering, image display, document summary)
- A metadata section (file type, size, dates)
- A **commentary area** — editable Markdown where the user can add their own notes, annotations, and context about the file

The commentary area is the proxy note's real value. It lets the user annotate non-text files without converting them. "This is the Q3 budget spreadsheet. Key numbers: mobile budget is $2M, up from $1.2M."

A proxy note can be **promoted** to a full note: the file becomes an attachment, and the commentary becomes the note body. This is a one-way escalation for when a proxy note grows enough to deserve its own identity.

Proxy notes are indexed by the BERT model — both the file's extractable text and the user's commentary. They appear in search results and graph links like any other note.

---

## Tabs

Tabs follow the Chrome model exactly. The tab bar sits above the search bar:

```
Tab > Search Bar > Space > Editor
```

Each tab maintains its own state:
- Active note (what's in the editor)
- Miller column position (where in the tree)
- Search query (if any)

Standard keyboard shortcuts apply:
- **Cmd+T** — new tab (bar focused, Miller columns at tree root, editor empty)
- **Cmd+W** — close tab
- **Cmd+1/2/3** — switch tabs
- **Cmd+Enter** from search — open result in new tab

A new tab has an empty editor with a placeholder ("Start typing to search or create a note"). The bar is focused. Miller columns show the tree root. This is the "blank page" state — inviting, not intimidating.

---

## Quick Capture

When the app isn't in focus, a global shortcut (e.g., **Cmd+Shift+Space**) summons a **floating panel** over the current app — like Spotlight, but for notes.

```
┌───────────────────────────────────────┐
│ 🔍 Idea: use BERT for note filing      │
├───────────────────────────────────────┤
│ ▸ ML Research Ideas    Research  82%  │
│ ▸ App Architecture     Tech     71%  │
│                                       │
│ ↵ Create in Research › ML Ideas       │
└───────────────────────────────────────┘
```

The panel has the search bar and a compact results list. The BERT suggestion appears at the bottom as a **default action** — not a question to answer, but a decision already made that the user can override.

### Fast path (the 90% case)

```
Cmd+Shift+Space          → panel appears, cursor in bar
"idea: BERT for filing"  → type the title
                         → results + filing suggestion appear
Enter                    → note created at suggested location
                         → panel dismisses
                         → back to whatever you were doing
```

Three actions. Under five seconds. The note is properly filed without a filing decision.

### With a body

**Tab** expands a text area below the results:

```
┌───────────────────────────────────────┐
│ 🔍 Idea: use BERT for note filing      │
├───────────────────────────────────────┤
│ ▸ ML Research Ideas    Research  82%  │
│ ↵ Create in Research › ML Ideas       │
├───────────────────────────────────────┤
│ Could use cloze-style tasks to        │
│ generate training data from the       │
│ user's note collection.               │
│                             Cmd+↵ Save│
└───────────────────────────────────────┘
```

Tab reveals the body field. **Cmd+Enter** saves and dismisses.

### Override the suggestion

Arrow to a different search result and Enter to file as a sibling of that note. Or type more precisely — adding words that signal a different topic area until BERT updates its suggestion. The same interaction model as the in-app bar — the floating panel is just the bar extracted from the app.

### Capture from selection

If text is selected in another app when the shortcut is invoked, the selected text becomes the note body. The user types a title. BERT suggests a location based on both title and body content.

### Feedback loop

The next time the user opens the app, a subtle notification appears:

```
🌱 Quick capture: 3 notes filed since last visit
   ▪ "BERT for filing" → Research › ML Ideas
   ▪ "Sprint retro feedback" → Work › Q3 Planning
   ▪ "Book rec from Sarah" → Personal › Reading List
   [Looks right] [Review]
```

One click to confirm. "Review" opens the notes for refiling. This closes the loop: quick capture is fast *and* correctable, and corrections feed back into the BERT model.

---

## The Intelligence Layer: BERT

The app's intelligence is powered by a local BERT model. Not a large language model. Not a cloud API. A small, fast, on-device model that understands the user's notes and improves over time.

### Why BERT?

The app's intelligence needs are all **classification and matching** tasks, not generation tasks. The system doesn't write text — the user does that. The system predicts: which folder? which related notes? which duplicates? These are cloze tasks — predicting a missing piece given surrounding context — and BERT was literally pre-trained for this.

The core cloze formulations:

| Task | Cloze form |
|------|-----------|
| Filing | "This note belongs in **[MASK]** folder" |
| Linking | "This note is related to **[MASK]** notes" |
| Searching | "The user typing this query wants **[MASK]** note" |
| Deduplication | "This note and **[MASK]** are substantially similar" |
| Gap detection | "This folder is missing a note about **[MASK]**" |

BERT is also the right *size*. A DistilBERT model (66M parameters) runs inference in under 10ms on Apple Silicon. The filing suggestion is ready before the user finishes typing. No API calls, no latency, no privacy concerns. Everything runs locally.

### Training progression

#### Day one: pre-trained embeddings

Use a pre-trained sentence-transformer model (e.g., `all-MiniLM-L6-v2`, 22M parameters). Embed every note. Store embeddings in a local vector index.

This gives semantic search immediately. "james q3 mobile" finds "Q3 Roadmap Priorities" via embedding similarity even with low word overlap. Filing suggestions use nearest-neighbor voting: find the most similar existing notes, suggest whatever folder the majority live in.

Rough but functional. No training required.

#### First adaptation: continued MLM pre-training

Run standard masked language modeling on the user's note collection. Randomly mask 15% of tokens, predict them. This adapts the model's language understanding to the user's domain.

After this step, the model knows that "James" is a person associated with "Q3" and "mobile," that "replatform" is a concept this user cares about, that "sprint" appears in planning contexts. The embedding space warps to reflect this user's world.

Cost: a few hundred notes, a few minutes on Apple Silicon with MLX. Run once at setup, re-run periodically.

#### Ongoing: task-specific cloze fine-tuning with LoRA

Design training examples that match the app's tasks:

**Filing:**
```
[CLS] Meeting with James — discussed Q3 roadmap,
he wants to prioritize mobile [SEP] This note
belongs in [MASK] [SEP]
→ Target: "Q3_Planning"
```

**Linking:**
```
[CLS] Q3 Roadmap Priorities [SEP] is related to
[SEP] Meeting with James [SEP] [MASK]
→ Target: "true"
```

**Deduplication:**
```
[CLS] Q3 Roadmap Priorities [SEP] Q3 Mobile
Plan [SEP] These notes are [MASK]
→ Target: "duplicate"
```

Generate training data from the user's existing collection: each note's actual folder provides filing examples, notes in the same folder provide linking examples, high-similarity pairs provide dedup candidates.

Fine-tune using LoRA (Low-Rank Adaptation): freeze the base model, add small adapter matrices (<1% of parameters). This is:

- **Fast** — seconds to train, not minutes
- **Cheap** — tiny memory overhead
- **Reversible** — delete the adapter if something goes wrong
- **Composable** — separate adapters per task if needed

#### Online learning loop

Every user action generates training signal:

| User action | Training signal |
|-------------|----------------|
| Accept filing suggestion | Positive (note, folder) pair |
| Refile a note | Negative (old folder) + positive (new folder) |
| Merge two notes | Positive dedup pair |
| Dismiss merge suggestion | Negative dedup pair |
| Create manual link | Positive link pair |
| Remove a link | Negative link pair |

Signals accumulate in a buffer. When the buffer reaches a threshold (~20 examples), a LoRA update runs in the background. The user never sees this.

**The result: every act of garden tending makes the gardening assistant smarter.** Filing teaches it where things go. Merging teaches it what similarity means. The garden and the gardener co-evolve.

### Handling a growing tree

The folder vocabulary changes as the user creates new folders. Rather than adding special tokens, the model encodes the note and each candidate folder name separately, scoring each pair. With typical collections having fewer than 100 folders, the cost is negligible.

---

## Garden Tending

The app doesn't have a separate "review" or "organize" mode. Garden tending is woven into the existing UI surfaces:

### Inline suggestions

When viewing a note, the editor shows relevant suggestions below the content:
- "Similar to 'Q3 Mobile Plan' — **Merge?** / Dismiss"
- "This note has been in Inbox for 3 days — **File?**"
- "No backlinks to this note"

When viewing a folder outline, suggestions appear in context:
- "These two child notes have 87% overlap"
- "This folder has 40 notes — consider splitting"
- "3 notes elsewhere might belong here"

### The Inbox

When creating a note and the system has no confident filing suggestion, the user has two options:

- **File manually** — navigate the Miller columns to choose a location, or type more precisely in the bar until BERT suggests the right place
- **File to Inbox** — the note goes to a special unfiled location

The Inbox is designed with **escalating pressure** to prevent note rot:

| Inbox state | UI response |
|-------------|-------------|
| 0 items | Gray icon, essentially invisible |
| 1-5 items, < 24 hours | Subtle dot indicator, no count |
| 1-5 items, > 24 hours | Number badge appears |
| 6-15 items | Yellow badge, gentle nudge in garden suggestions |
| 16+ items | Red badge. "Your inbox is overgrown" banner. Inbox items appear in folder outlines as unfiled with suggested locations. |

The pressure scales with both count and age. Five notes from today are fine. Five notes from two weeks ago need attention.

Crucially, the BERT model keeps trying to file Inbox items. As the user adds more notes and the model improves, it revisits unfiled notes: "You've filed 6 similar notes in Work > Q3 Planning since this arrived. File here too?" This turns Inbox tending from "stare at a note and decide" into "review and approve suggested locations."

---

## Summary

This app is NV's philosophy — speed, simplicity, writing-first — rebuilt for the realities of modern knowledge work. The key innovations:

1. **Filing as a byproduct of capture**, not a prerequisite. The BERT model suggests where each note belongs. The user accepts by pressing Enter.

2. **Two structural layers**: a user-defined tree for intentional organization and an auto-generated graph for emergent connections. Neither alone is sufficient; together they cover how humans actually think about knowledge.

3. **A three-pane vertical stack** that puts writing first. The space (Miller columns / search results) is collapsible context, not a permanent sidebar. The editor dominates.

4. **Folders as outlines**: opening a folder shows its contents as an editable, Roam-style outline — the natural surface for seeing a category at a glance and tending it.

5. **Proxy notes** for non-Markdown files, making the app a window into a real knowledge base, not just a Markdown editor.

6. **A local BERT model** that learns from the user's filing decisions, improving over time through cloze-style LoRA fine-tuning. The garden and the gardener co-evolve.

7. **Quick capture** via a floating panel that carries full filing intelligence, making it possible to properly file a note in under five seconds without leaving the current app.

The name is TBD. But the soul is clear: it's Notational Velocity for people whose knowledge outgrew a flat list — without becoming Obsidian for people who'd rather be writing.
