import Foundation

/// One undoable command — the Command pattern over the buffer: a
/// logged sequence of primitive contiguous swaps (steps), each
/// recorded against the EVOLVING buffer (a step's offset is valid at
/// the moment that step was applied — undo walks the log backwards
/// replaying inverse swaps, redo replays it forward; both are exact
/// because undo restores the precise pre-operation state, and any
/// new edit discards the redo stack, so a replayed log can never
/// meet a state it did not come from).
///
/// Two sides, deliberately separate:
/// - BUILD (the executor): `delete/insert/replace(buf, …)` mutate
///   the buffer AND log the step in the same call — the log cannot
///   drift from the mutations by construction, the caller never
///   touches the buffer directly. A no-op invocation (a zero-length
///   delete, an empty insert) mutates nothing and logs nothing; an
///   identity `replace` (the old text equals the new) is skipped
///   whole — an identity swap is not an edit (this is exactly the
///   `:s/x/x/` guard, moved to the only place that can enforce it
///   for free: replace reads the old text anyway to log it).
/// - REPLAY: `Step.apply(to:)` is the single primitive; op-level
///   `apply(to:)` is the loop over it; `inverted()` is the log
///   transform (steps reversed, each swap exchanged) — anchors are
///   NOT transformed, they belong to the forward operation and are
///   never read from an inverted copy.
///
/// Anchors: the optional `undoAnchor`/`redoAnchor` say where the
/// cursor parks on undo/redo; nil — the defaults (`firstOffset` /
/// `lastInsertionEnd`, i.e. where the command began / where its last
/// insertion ended). A composite site whose command began far from
/// its first step (vim's `:s` parks at the RANGE start, not at the
/// first applied edit) sets them explicitly at commit.
///
/// The undo/redo CURSOR DRIVE and LSP tracking stay with the window
/// (EditorWindow.undo/redo): they interleave a per-step
/// trackLSPChange with each step's application — positions are valid
/// because a step's own mutation never moves the line start or
/// column of its offset (both are determined by content strictly
/// before it), and no later step may run before this step's tracking.
public struct EditOperation: Equatable {
    /// One contiguous swap: delete `deleted`, insert `inserted`, both
    /// at `offset`. Byte offsets (PieceTable's address space).
    public struct Step: Equatable {
        public let offset: Int
        public let deleted: String
        public let inserted: String

        public init(offset: Int, deleted: String, inserted: String) {
            self.offset = offset
            self.deleted = deleted
            self.inserted = inserted
        }

        /// The step's forward application — the same shape the flat
        /// undo action always had: delete the old text, insert the
        /// new, both at the step's offset.
        public func apply(to buf: PieceTable) {
            if !deleted.isEmpty { buf.delete(at: offset, length: deleted.utf8.count) }
            if !inserted.isEmpty { buf.insert(inserted, at: offset) }
        }
    }

    public private(set) var steps: [Step]
    /// Explicit cursor anchors (see the type doc); nil — the defaults.
    public var undoAnchor: Int?
    public var redoAnchor: Int?

    public init(steps: [Step] = []) {
        self.steps = steps
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// The default undo anchor — the first step's offset (where the
    /// command began). Nil for an empty operation.
    public var firstOffset: Int? { steps.first?.offset }

    /// The default redo anchor — the end of the last step's
    /// insertion (the flat action's `offset + inserted.length`).
    public var lastInsertionEnd: Int? {
        guard let last = steps.last else { return nil }
        return last.offset + last.inserted.utf8.count
    }

    // MARK: - Replay

    /// Forward replay, in log order — each step's offset is valid at
    /// its position in the sequence by construction.
    public func apply(to buf: PieceTable) {
        for step in steps { step.apply(to: buf) }
    }

    /// The inverse log: steps reversed, each swap exchanged. Applying
    /// it to the post-operation buffer restores the pre-operation
    /// state exactly; `inverted().inverted()` is the original
    /// (involution). Anchors are left nil — they belong to the
    /// forward operation.
    public func inverted() -> EditOperation {
        EditOperation(steps: steps.reversed().map {
            Step(offset: $0.offset, deleted: $0.inserted, inserted: $0.deleted)
        })
    }

    // MARK: - The executor: mutate and log, inseparably

    /// Delete `length` bytes at `offset` — the deleted text is read
    /// HERE (the log's truth is what the buffer held, not what the
    /// caller believes). A zero-length delete is nothing at all.
    /// Returns the logged step (nil — a no-op, nothing happened).
    @discardableResult
    public mutating func delete(_ buf: PieceTable, at offset: Int, length: Int) -> Step? {
        guard length > 0 else { return nil }
        let text = buf.getText(range: offset..<(offset + length))
        buf.delete(at: offset, length: length)
        let step = Step(offset: offset, deleted: text, inserted: "")
        steps.append(step)
        return step
    }

    /// Insert `text` at `offset` — an empty insert is nothing at all.
    /// Returns the logged step (nil — a no-op).
    @discardableResult
    public mutating func insert(_ buf: PieceTable, _ text: String, at offset: Int) -> Step? {
        guard !text.isEmpty else { return nil }
        buf.insert(text, at: offset)
        let step = Step(offset: offset, deleted: "", inserted: text)
        steps.append(step)
        return step
    }

    /// Replace `length` bytes at `offset` with `text` — ONE atomic
    /// step (a swap, not a delete+insert pair). An identity swap
    /// (old == new) is skipped whole: not an edit, no step, no
    /// mutation — the `:s/x/x/` guard at the only place that can
    /// enforce it for free. Returns the logged step (nil — a no-op).
    @discardableResult
    public mutating func replace(_ buf: PieceTable, at offset: Int, length: Int, with text: String) -> Step? {
        guard length > 0 || !text.isEmpty else { return nil }
        let old = length > 0 ? buf.getText(range: offset..<(offset + length)) : ""
        if old == text { return nil }
        if length > 0 { buf.delete(at: offset, length: length) }
        if !text.isEmpty { buf.insert(text, at: offset) }
        let step = Step(offset: offset, deleted: old, inserted: text)
        steps.append(step)
        return step
    }
}
