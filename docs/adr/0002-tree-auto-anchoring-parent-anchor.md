# ADR 0002: Tree auto-anchoring — the parent anchor (rule C)

- **Status:** Accepted
- **Date:** 2026-11-09
- **Ships in:** v0.1.29 (TreeScroll.swift, TreeListController, both tree windows)
- **Supersedes:** the manual-only horizontal shift as the sole deep-tree tool

## Context

A tree row's indent is `depth * 2` cells. In a deep tree inside a narrow side
panel (the explorer is floored at 22 columns), a depth-4 file name starts
around cell 11 — past the right edge long before the name does. Until
v0.1.28 the only tool was the manual Left/Right shift (step of 4), which had
to be repeated by hand on every descent.

We studied the precedents first:

- **IntelliJ/PyCharm (Swing JTree)** scrolls descendants into view on expand
  (`scrollsOnExpand`, default true) via `JViewport.scrollRectToVisible` —
  the documented doctrine is "scroll only as much as necessary".
- **VS Code** opts out of tree horizontal scrolling entirely (labels
  ellipsize; `workbench.list.horizontalScrolling` is opt-in and manual).
  Its tree keys, however, match swim's exactly: LeftArrow on a collapsed
  row → reveal + focus the parent (swim's `h`), RightArrow on an expanded
  row → reveal + focus the first child (swim's `l`).

An intermediate iteration ("rule B" — minimum movement into a span
visibility window, tails winning when the span is wider than the window)
shipped briefly inside the branch and was **rejected on field evidence**:
aligning to the widest row's TAIL showed `…усском.swift` — the tail is the
least recognizable half of a name, and the parent directory (the "where am
I" context) was cut off the left edge entirely.

## Decision

### The law (one formula, every case)

After any view-changing tree interaction the horizontal view anchors so the
**PARENT of the attention** sits at the left edge — its icon and name first,
the attention one indent (2 cells) to the right:

```
anchor = max(0, (attentionDepth − 1) * 2)
```

The trigger is **"if it doesn't fit"**: the view keeps the current offset
while the **parent-anchored picture** — the parent's indent cell through the
attention's last cell — is fully visible in the window; when it is not, the
view jumps to the anchor. A picture wider than the window never counts as
visible (the long-name case always anchors — heads readable, tails clip).

### What the "attention" is, per operation

| Operation | Attention | Anchor shows |
|---|---|---|
| Expand (Enter / `l`) | the strip of new rows below the branch (its children — match lines for a search file) | the branch itself, children one indent in |
| Collapse — **Enter on an expanded dir** | the dir itself (cursor stays on it) | **its parent**, the dir one indent in |
| Collapse — **`h`** | the row `h` selects and folds (see below) | **that row's parent** |
| Reveal / selection-restoring rebuilds (`H`, `:fe reset`, delete, search freshness) | the selected row | its parent |

### The collapse semantics (the "sometimes 2 levels" explained)

`h` is **not** "collapse what I stand on". It is *"leave the branch and fold
it"*: the target is the nearest row above one depth shallower (the selected
row's parent); the cursor moves there and the **target** collapses if it was
expanded. Therefore:

- `h` **on a file/child** (inside dir X): collapses **X** → anchor = X's
  parent. One level up from X.
- `h` **on an expanded dir X**: the target is X's **parent** P → collapses
  **P** → anchor = P's parent. Two levels up from X — because `h` first
  stepped up to P and folded P's whole branch.
- `h` on a collapsed row / at the top level: nothing to fold; the cursor
  just moves to the parent (top level: stays).

**Enter is the key for "collapse this directory and see its parent"**;
`h` is the key for "get me out of this branch". This asymmetry is
long-standing (identical in v0.1.28) and matches VS Code's
LeftArrow-on-a-collapsed-row behavior.

Related: collapsing **wipes the expansion memory** of the whole subtree —
re-expanding opens the node fresh (its children collapsed). The
loaded-children disk cache survives, so re-expansion is instant.

### Why the visibility check IS the anchor's own picture

A rule-B-era hole: the check tested only the attention's span, so an offset
left parked to the right by an earlier deep expand could satisfy "row
visible" while the parent was cut off-screen — a collapse then appeared not
to show the parent. Because the checked span now **starts at the anchor**,
an offset right of the parent fails the check *by construction*. The pure
function's API enforces this permanently: it takes `(current, width,
anchor, end)` — a span decoupled from the anchor cannot even be expressed.

Invariants, both provable: after every snap — keep or jump — the parent's
name is on screen (keep: `current ≤ anchor` and `current + width ≥ end >
anchor + 3`; jump: the pre-clamped anchor plus the bound covers the same
cells), and the resulting offset never sits right of the manual-shift
bound, so a later Right never jumps left.

### The clamp

The anchor is pre-clamped by the manual-shift bound (the widest **visible**
row: everything past its end is blank). When the remaining content is short
relative to the depth, the clamp pulls the anchor further LEFT — more
ancestors visible than the parent, never fewer, never blank view. The
attention strip is likewise intersected with the vertical viewport: "make
readable what is on screen", which is also what keeps the bound honest.

### Degenerate geometry decides nothing

A window not yet laid out (0×0 — the boot state) must not produce view
movement: `TreeScroll` returns `current` unchanged for width ≤ 0, and
`Window.clampedScroll` no-ops a viewport with visibleCount ≤ 0 (its old
arithmetic produced `scroll = selectedIndex + 1` — *past the end of the
list*). This pair fixed the `swim <file>` boot bug: the boot reveal used to
run against 0×0 windows, so the tree opened scrolled past its own end and
looked empty/shifted. The boot reveal now runs **after the first layout**,
between `relayout()` and the first `render()`, landing on the opened file's
parent directory at the left edge.

## Consequences

- Deep trees need no manual shifting: expand/collapse/reveal self-anchor,
  with name HEADS always readable (tails clip on names longer than the
  window — the head is the recognizable half).
- The user's manual scroll position is respected whenever the
  parent-anchored picture fits ("if it doesn't fit" is the only trigger).
- Works identically in the file explorer and the search tree (the shared
  TreeListController component — one implementation, tested math in
  SwimCore `TreeScroll`, 8 unit cases + a pty behavioral matrix:
  narrow/wide, Cyrillic names, resize loops, the boot fix).
- Known acceptable edge: expanding an **empty** directory anchors nothing
  (no rows appear — no attention); a resize does not re-anchor by itself
  (the next interaction does).

## Alternatives considered

- **Rule B — minimum movement, tails on overflow:** rejected after field
  use (unrecognizable name tails, parent context lost); kept as the
  manual-shift bound semantics inside `shiftHorizontally`.
- **Rule A — always anchor the branch level, unconditionally:** moves the
  view even when everything already fits; the "if it doesn't fit" trigger
  of rule C keeps wide windows perfectly still.
- **VS Code-style ellipsis:** a terminal cannot cheaply offer hover
  tooltips; clipping must choose a side, and we choose heads.
- **Auto-center / relative offsets:** unpredictable, no precedent found.

## References

- ARCHITECTURE.md — "Window/TreeListView.swift", `TreeScroll.swift` entries
- Sources/SwimCore/TreeScroll.swift (the pure rule, doc comment)
- Tests/SwimCoreTests/TreeScrollTests.swift
- Swing `JTree.scrollsOnExpand` / `JViewport.scrollRectToVisible`;
  VS Code `abstractTree.ts` onLeftArrow/onRightArrow (the precedent study)
