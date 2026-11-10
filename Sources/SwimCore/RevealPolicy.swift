/// The vertical reveal math of the viewport — ONE pure rule per
/// doctrine, the vertical twin of TreeScroll; the edge-clamp law is
/// shared by the editor AND the list windows (Window.clampedScroll
/// delegates here). Dependency-free and side-effect-free; tested in
/// Tests/SwimCoreTests/RevealPolicyTests.swift.
///
/// - Edge clamp (motions, plain gg/G, n/N, list windows): the view
///   moves only to pull the cursor back inside; a visible cursor
///   decides nothing. Minimal motion — the cursor may land on the
///   first or last visible row.
/// - Jump reveal (gd / gb / :N / search results / counted Ngg, NG):
///   the target lands at ~1/3 of the visible height from the top —
///   signature and docs above, the body below.
public enum RevealPolicy {

    /// Keeps `scrollY` while `cursorLine` is inside the visible window
    /// `[scrollY, scrollY + contentHeight)`; otherwise shifts the view
    /// the minimum needed to pull the cursor back to the edge. A
    /// degenerate height (a window not yet laid out) decides nothing —
    /// the current offset stands. Total for any input; never negative.
    public static func edgeClamp(cursorLine: Int, scrollY: Int, contentHeight: Int) -> Int {
        guard contentHeight > 0 else { return scrollY }
        if cursorLine < scrollY { return cursorLine }
        if cursorLine >= scrollY + contentHeight { return cursorLine - contentHeight + 1 }
        return scrollY
    }

    /// The scroll offset a JUMP installs so its target row sits at
    /// ~1/3 of the visible height from the top (integer floor —
    /// slightly above the exact third, more body below). Clamped at
    /// both buffer edges: a target near the top parks at the file's
    /// first line, one near the end at the last screenful. A degenerate
    /// height yields 0 — the top of the file, matching
    /// ensureCursorVisible's degenerate reset. Total for any input;
    /// never negative, never past `max(0, lineCount - contentHeight)`.
    public static func jumpScrollY(cursorLine: Int, lineCount: Int, contentHeight: Int) -> Int {
        guard contentHeight > 0 else { return 0 }
        return min(max(0, cursorLine - contentHeight / 3),
                   max(0, lineCount - contentHeight))
    }
}
