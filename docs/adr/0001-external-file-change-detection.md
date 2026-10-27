# ADR 0001: External file-change detection (buffer freshness)

- **Status:** Accepted
- **Date:** 2026-10-28
- **Supersedes:** the "mtime-sweep after commands only" behavior (the sweep code stays, its trigger set widens)

## Context

Swim buffers go stale when a file is rewritten by something other than swim —
an AI agent in another terminal, `sed -i`, a formatter, a build step. The
existing machinery already had the entire reload decision matrix (per-tab
mtime recorded at open/save, clean-tab reload preserving cursor/scroll/mode,
content comparison against false positives, the vim-W12 write guard, deleted
files keeping their in-memory buffer) but only two trigger families: git
commands finishing through CommandWindow and commands finishing in the
built-in terminal. An external edit with no command inside swim was invisible
until restart.

We studied how vim and Neovim solve this in production (docs + empirical
verification against nvim 0.11.5 in a pty):

- Both record **mtime + size + mode** per buffer and compare at chosen
  moments — neither uses inotify/fs-events for buffers. Neovim even disables
  the LSP `didChangeWatchedFiles` capability on Linux by default ("no viable
  backend that scales well"): inotify is non-recursive, watch-limited, and
  broken by atomic-rename writers (`sed -i`) unless directories are watched.
- Neovim's trigger set: **shell-command return, FocusGained, `:checktime`,
  pre-write**. nvim enables terminal focus reporting (`ESC[?1004h`) by
  default and silently reloads clean buffers on focus return (`autoread` on
  by default). Verified empirically: external append + injected `CSI I` →
  silent reload; dirty buffer → W12 prompt, buffer preserved; identical
  bytes rewritten → nothing (content comparison); deleted file → E211,
  buffer survives.
- The 4-second `CursorHold` + `checktime` recipe is user config, not core.
  Classic vim cannot even get focus events in a terminal without manual
  `t_fe` setup — the recipe exists to compensate. We explicitly rejected the
  idle timer: no polling loops, event-driven only.

## Decision

Four independent lanes, one sweep funnel. The invariant: **you cannot look at
a buffer without having just arrived at the editor; arrival syncs the world;
a write is guarded regardless of every other lane.**

1. **Arrival (new).** Terminal focus reporting (`ESC[?1004h` at setup,
   `ESC[?1004l` at restore; `CSI I`/`CSI O` parsed as `Key.focusGained` /
   `.focusLost`) and internal focus arriving at the editor window
   (`focus()` / `focusStackTop()` — both funnels; closing a window pops
   through the latter). Both only set `worldCheckPending`; the run loop
   executes the sweep at the **top of the next iteration — between keys,
   never inside key handling** (vim postpones `checktime` from autocmds to a
   harmless moment; `EditorBuffer` is a class, and a sweep inside `focus()`
   would swap `buffers` slots under code holding references).
2. **Shell return (existing).** `gitCommandFinished` /
   `terminalCommandFinished` call the same sweep — vim's `:!cmd` moment.
   Long/interactive agents keep this covered even while the user never
   leaves the editor.
3. **Own writes (existing).** `fileChangedOnDisk(path)` — swim itself
   rewrote a known file (git-panel discard): precise, immediate, per-file.
   Not a sweep: the editor is visible beside the panel and must update
   without a focus hop.
4. **Write safety (existing, upgraded).** `saveOrConfirm` compares a
   **fingerprint of mtime + size** (vim's triple minus mode, which we don't
   need) — one `attributesOfItem` call, no extra syscalls. The fingerprint
   is a cheap pre-filter; the content comparison in `reload` remains the
   arbiter, so a false positive (`touch`) is harmless. A nil stamp on disk
   skips the guard — `:w` recreates a deleted file (vim semantics).

All four lanes funnel through `reloadChangedOnDisk` → `applyBufferReload`
(repaint, git stats, full LSP content resync). No `WindowDelegate` changes.

### Guard rules discovered by review (mandatory)

- **Modal sessions**: the sweep skips the *active* tab while the editor
  holds an interactive session (`:s//c` confirm, changed-on-disk write
  confirm) — their pending byte offsets and `w/r/q/a` semantics live against
  the old instance. Non-active tabs reload freely; the skipped tab is caught
  by the next trigger.
- **Armed substitution scope**: a reload of the *active* tab while its
  command line is open (a focus event can arrive mid-`'<,'>s`-typing)
  invalidates `pendingSubstituteScope` — its line numbers and byte windows
  belong to the old instance and would clamp silently onto the new text.
  The typed command then reports "Selection range expired" — the designed
  degradation (the scope belongs to exactly one command session).
- **Visual anchor**: `reload` copies and clamps `visualStartLine/Col`
  alongside cursor/scroll/mode — a reload in a visual mode must not reset
  the anchor to the origin (phantom selection from the file start). This was
  a latent bug predating the feature; frequent reloads activated it.
- **Dirty tabs** are never touched (unsaved edits outrank the disk) —
  unchanged doctrine.

## Consequences

**Positive**
- The user's primary workflow (agent edits in another terminal → return to
  swim) refreshes silently, exactly like nvim; data safety never depends on
  freshness (the write guard is independent).
- Strictly additive: no existing lane was removed or weakened; one sweep
  funnel; no new threads, loops or platform APIs (works on Linux and macOS).

**Negative / accepted limitations**
- Terminal focus reporting is environment-dependent: tmux needs
  `set -g focus-events on`; macOS Terminal.app never sends focus events.
  In those environments lanes 2–4 still work; documented in README.
- An agent writing while the user stays continuously inside swim (no focus
  transition at all) is refreshed only on the next arrival — identical to
  nvim core behavior; the idle-timer alternative was explicitly rejected.
- A write landing in the millisecond window between our `:w` and the
  re-stat is invisible until the next disk change (vim has the same race).

## Alternatives considered

- **4-second idle timer (vim's `CursorHold` recipe)** — rejected: a polling
  concept; vim ships it as user config, not core; the loop gains a trigger
  that fires with no event behind it.
- **inotify/fs-events watcher** — rejected: production (Neovim) deliberately
  avoids it for buffers; watch limits, non-recursive watches, atomic-rename
  breakage, and per-platform code (inotify vs FSEvents) in a
  zero-dependency project.
- **Focus-only triggers (delete the command-time sweeps)** — rejected: the
  built-in terminal completes commands asynchronously; a completion while
  the user already sits in the editor would go unnoticed until the next
  focus hop. Keeping the shell-return lane is vim's own `:!cmd` doctrine.
- **mtime-only fingerprint (status quo)** — upgraded to mtime+size: same
  single stat call, robust on coarse-mtime filesystems (NFS/SMB), and
  consistent with PreviewWindow/SearchResults which already fingerprint
  this way.

## References

- vim `:h timestamp`, `:h autoread`, `:h FileChangedShell`, `:h xterm-focus-event`
- Neovim `autocmd.txt` (FileChangedShell triggers: shell command /
  `:checktime` / `FocusGained`), `news-0.10` (didChangeWatchedFiles disabled
  on Linux), `lua.txt` `*watch-file*` (inotify limits)
- Empirical pty verification of nvim 0.11.5: focus-reporting enabled by
  default; the full reload/warning matrix confirmed
- ARCHITECTURE.md — the four-lane doctrine section
