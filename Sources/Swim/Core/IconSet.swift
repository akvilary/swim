import SwimCore

/// The active icon tier for this process — set once in main.swift
/// from SWIM_ICONS and the color capability (the AppLocale doctrine:
/// a value, immutable for the process lifetime). The tables and the
/// resolution policy live in SwimCore (Icons.swift, tested); this is
/// the executable's thin binding, the same seam as Color.outputSupport.
enum IconSet {
    nonisolated(unsafe) static var tier: IconTier = .nf
}
