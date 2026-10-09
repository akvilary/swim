/// Tab policy for text ENTERING the editor (paste from the system
/// clipboard, the typed Tab key): one tab is one indent step, replaced
/// with `indent` spaces — the same width the auto-indenter and the
/// H/L shift produce, so pasted indentation reads identically to typed
/// indentation. Text without tabs returns untouched (the common case —
/// no copy). Files already in the buffer are never rewritten by this;
/// the internal yank/paste round-trip (p/P) also stays verbatim.
///
/// `replacing(_:with:)` is the stdlib (SE-0357, Swift 5.7) — no
/// Foundation import needed.
public enum TabPolicy {

    public static func expandTabs(_ text: String, indent: Int) -> String {
        guard text.contains("\t") else { return text }
        return text.replacing("\t", with: String(repeating: " ", count: max(1, indent)))
    }
}
