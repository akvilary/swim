import Foundation

/// The application locale — the single source of truth for the
/// language of the system messages swim displays: git output (branch
/// dates, hints, errors — what the branch picker, the git panel and
/// the command window render), embedded-terminal commands and language
/// servers (the LSP `locale` handshake parameter, plus their process
/// environment). English by default.
///
/// A value, and immutable for the process lifetime by design. Locale
/// is process configuration, not runtime state: an LSP server keeps
/// the locale of its handshake until restart, so a mid-session switch
/// could only ever produce a mixed-language UI. `current` is the
/// single assignment point — today a constant, later the app config's
/// read — and every consumer derives from it, so there is no plumbing
/// and no invalidation to get wrong.
public struct AppLocale: Sendable {
    /// A language code ("en", "fr", …) — the spelling both worlds
    /// understand: LSP servers take it verbatim, the subprocess
    /// environment derives its POSIX spelling. A region-qualified id
    /// ("en_GB") is honored as-is.
    public let id: String

    /// The process-wide locale. English until the app config lands.
    public static let current = AppLocale(id: "en")

    public init(id: String) {
        self.id = id
    }

    /// Environment overrides that pin a subprocess to this locale
    /// instead of the system's:
    ///
    /// - `LANGUAGE` — gettext's priority list, which outranks even
    ///   LC_ALL: inherited from a French desktop ("fr_FR:ru:en"), it
    ///   would keep translating git ("il y a 2 heures") past any
    ///   LC_ALL override — including a C.UTF-8 one. Always set, always
    ///   derived from the id (catalog-lookup names are their own
    ///   namespace, independent of the LC_ALL spelling).
    /// - `LC_ALL` — the strongest standard knob, but its spelling must
    ///   EXIST on the box: an ungenerated locale does not degrade
    ///   gracefully for every child (glibc silently lands C — English
    ///   messages, but byte-oriented LC_CTYPE escapes non-ASCII
    ///   output, and programs that setlocale() explicitly die —
    ///   Python's classic "unsupported locale setting"). English
    ///   therefore resolves to a spelling guaranteed present (see
    ///   `lcAll(for:)`); other languages take the doubling heuristic
    ///   and degrade to English where their locale is not generated.
    public var environmentOverrides: [String: String] {
        let language = String(id.prefix(while: { $0 != "_" }))
        let localeName = id.contains("_") ? id : "\(id)_\(id == "en" ? "US" : id.uppercased())"
        return [
            "LC_ALL": Self.lcAll(for: id),
            "LANGUAGE": "\(localeName):\(language)"
        ]
    }

    /// The POSIX spelling for LC_ALL. English — the default, always in
    /// play, in any spelling ("en", "en_GB") — resolves to a locale
    /// the box certainly has: `C.UTF-8` on Linux (builtin to glibc
    /// >= 2.35, shipped on the Debian family, harmlessly ignored by
    /// musl, which has no locale machinery; its messages are English
    /// either way) and `en_US.UTF-8` on macOS (always generated) —
    /// system messages do not meaningfully differ across English
    /// variants, and a spelling that may not exist would reintroduce
    /// the invalid-locale failure mode above. Other languages use the
    /// doubling heuristic ("fr" -> "fr_FR.UTF-8"; a region-qualified
    /// id passes through).
    private static func lcAll(for id: String) -> String {
        if !id.hasPrefix("en") {
            return id.contains("_")
                ? "\(id).UTF-8"
                : "\(id)_\(id.uppercased()).UTF-8"
        }
        #if canImport(Darwin)
        return "en_US.UTF-8"
        #else
        return "C.UTF-8"
        #endif
    }

    /// The environment every subprocess spawn site passes: the given
    /// base (the inherited environment by default) with this locale's
    /// overrides applied on top — they win. All of swim's `Process`
    /// spawns go through here, so the policy exists exactly once.
    public func childEnvironment(over base: [String: String]? = nil) -> [String: String] {
        let inherited = base ?? ProcessInfo.processInfo.environment
        return inherited.merging(environmentOverrides) { _, override in override }
    }
}
