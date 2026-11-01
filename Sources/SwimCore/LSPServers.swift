import Foundation

/// LSP servers — THE single table of language-server wiring. One row
/// per server: the languages it serves (file extensions + didOpen
/// languageId) and its launch data (command, candidate paths, argv,
/// clangd-style fallback flags) and the typed post-start Behavior.
/// Routing and launch data cannot drift apart — they are the same row.
///
/// Projections cover both consumption directions: BY EXTENSION
/// (`serverKey`/`languageId`, the per-keystroke routing of every LSP
/// touchpoint) and BY KEY (`spec(forKey:)` — the key is the join token
/// of the wiring: this table emits it, `lspClients` is keyed by it,
/// behavior resolves from it). The pure half of server wiring; the
/// effectful half: discovery and the start loop live in
/// `Application.setupLSP` (the procedure, not the languages), behavior
/// in `LSPServerSetup` (an exhaustive switch over `Behavior`).
///
/// C family — TWO rows of one clangd binary, because the flagless
/// fallback standard is per language FAMILY: a `-std` flag carries the
/// family, so a single flat fallbackFlags list cannot serve both (a
/// probed .c under [-std=c++20] got the driver error "not allowed with
/// 'C'" AND parsed as C++ — false diagnostics on valid C). The C row
/// carries no fallback flags (clangd's own .c default, gnu17, is
/// already correct); the C++ row bumps the flagless default from
/// clangd's gnu++17 to c++20 (std::ranges unresolvable otherwise). A
/// compile database entry (cmake's CMAKE_CXX_STANDARD via
/// CMAKE_EXPORT_COMPILE_COMMANDS) always wins over any fallback. In the
/// C++ row `.h` opens as "cpp" — the hint matters only in the flagless
/// fallback, and C++ is the superset-safe choice for headers (a `.h`
/// with classes/templates must not parse as C or ObjC; plain C headers
/// survive C++ mode — the old "objective-c" mapping was dead code, `.h`
/// never reached a server). The extension set mirrors
/// `SyntaxTokenizer.keywords(for:)`'s C family — pinned by tests.
/// Upper-case `.C`/`.H` are deliberately unrouted: every extension
/// table in the project is case-sensitive.
///
/// The historical gaps this table closed (it replaced three drifting
/// vocabularies — Application's switch, SyntaxTokenizer.languageId and
/// the keyword table): `csx` → "csharp", `pyw`/`pyi` → "python" (they
/// fell to "plaintext" although their files reached a server), `hpp`/
/// `hxx` unlisted, `.h` mapped to a dead "objective-c".
public enum LSPServers {

    /// Post-start behavior beyond launch data — the executable
    /// (LSPServerSetup) switches on this exhaustively; a new case fails
    /// compilation there until handled.
    public enum Behavior: Sendable, Equatable {
        case none
        /// Push workspace settings via workspace/didChangeConfiguration
        /// unless the project carries its own server config.
        case pythonWorkspaceSettings
    }

    /// One language a server serves: the file extensions it covers (no
    /// dot, case-sensitive) and the didOpen languageId. A server with
    /// per-language variance (the C family's two parse modes) carries
    /// several entries; an extension must not appear twice across the
    /// whole table (pinned by tests).
    public struct Language: Sendable, Equatable {
        public let extensions: Set<String>
        public let languageId: String

        public init(extensions: Set<String>, languageId: String) {
            self.extensions = extensions
            self.languageId = languageId
        }
    }

    /// One server row. `fallbackFlags` become clangd-style
    /// initializationOptions.fallbackFlags — flags applied ONLY to the
    /// no-compile-database fallback command; a database entry (cmake's
    /// CMAKE_CXX_STANDARD via CMAKE_EXPORT_COMPILE_COMMANDS) always
    /// wins. `behavior` is the typed link to LSPServerSetup's switch —
    /// declared on the row, so a key rename can never detach it.
    public struct Spec: Sendable, Equatable {
        public let key: String
        public let command: String
        public let paths: [String]
        public let arguments: [String]
        public let fallbackFlags: [String]
        public let behavior: Behavior
        public let languages: [Language]

        public init(key: String, command: String, paths: [String],
                    arguments: [String] = [], fallbackFlags: [String] = [],
                    behavior: Behavior = .none, languages: [Language]) {
            self.key = key
            self.command = command
            self.paths = paths
            self.arguments = arguments
            self.fallbackFlags = fallbackFlags
            self.behavior = behavior
            self.languages = languages
        }

        /// The wire form of this row's server-specific initialize
        /// options (nil when the server needs none) — the clangd
        /// `fallbackFlags` key lives HERE, with the row's data, not in
        /// the caller's loop.
        public var initializationOptions: [String: Any]? {
            fallbackFlags.isEmpty ? nil : ["fallbackFlags": fallbackFlags]
        }
    }

    /// The clangd candidate paths — shared by the C family's two rows
    /// (one binary, per-family fallback), so the discovery list exists
    /// once and cannot drift between the rows.
    private static let clangdPaths: [String] = [
        "/usr/bin/clangd",
        "/usr/local/bin/clangd",
        "/home/linuxbrew/.linuxbrew/bin/clangd",
        "/opt/homebrew/bin/clangd",
        NSHomeDirectory() + "/.local/bin/clangd",
    ]

    public static let all: [Spec] = [
        Spec(
            key: "swift",
            command: "sourcekit-lsp",
            paths: [
                "/usr/bin/sourcekit-lsp",
                "/usr/local/bin/sourcekit-lsp",
                "/home/linuxbrew/.linuxbrew/bin/sourcekit-lsp",
                NSHomeDirectory() + "/.swiftenv/shims/sourcekit-lsp",
            ],
            languages: [Language(extensions: ["swift"], languageId: "swift")]
        ),
        Spec(
            key: "csharp",
            command: "omnisharp",
            paths: [
                "/usr/bin/omnisharp",
                "/usr/local/bin/omnisharp",
                NSHomeDirectory() + "/.dotnet/tools/omnisharp",
            ],
            arguments: ["-lsp"],
            languages: [Language(extensions: ["cs", "csx"], languageId: "csharp")]
        ),
        Spec(
            key: "go",
            command: "gopls",
            paths: [
                "/usr/bin/gopls",
                "/usr/local/bin/gopls",
                "/home/linuxbrew/.linuxbrew/bin/gopls",
                "/opt/homebrew/bin/gopls",
                NSHomeDirectory() + "/go/bin/gopls",
            ],
            languages: [Language(extensions: ["go"], languageId: "go")]
        ),
        Spec(
            key: "rust",
            command: "rust-analyzer",
            paths: [
                "/usr/bin/rust-analyzer",
                "/usr/local/bin/rust-analyzer",
                "/home/linuxbrew/.linuxbrew/bin/rust-analyzer",
                "/opt/homebrew/bin/rust-analyzer",
                NSHomeDirectory() + "/.cargo/bin/rust-analyzer",
            ],
            languages: [Language(extensions: ["rs"], languageId: "rust")]
        ),
        Spec(
            key: "bash",
            command: "bash-language-server",
            paths: [
                "/usr/bin/bash-language-server",
                "/usr/local/bin/bash-language-server",
                "/home/linuxbrew/.linuxbrew/bin/bash-language-server",
                "/opt/homebrew/bin/bash-language-server",
                NSHomeDirectory() + "/.npm-global/bin/bash-language-server",
                NSHomeDirectory() + "/.local/bin/bash-language-server",
            ],
            arguments: ["start"],
            languages: [Language(extensions: ["sh", "bash"], languageId: "shellscript")]
        ),
        // Python: basedpyright only — it is the pyright fork that implements
        // semantic tokens (pyright lacks them entirely). pip/uv install.
        // Its settings push after start is the row's Behavior, executed in
        // LSPServerSetup.
        Spec(
            key: "python",
            command: "basedpyright-langserver",
            paths: [
                "/usr/local/bin/basedpyright-langserver",
                "/usr/bin/basedpyright-langserver",
                "/home/linuxbrew/.linuxbrew/bin/basedpyright-langserver",
                "/opt/homebrew/bin/basedpyright-langserver",
                NSHomeDirectory() + "/.local/bin/basedpyright-langserver",
            ],
            arguments: ["--stdio"],
            behavior: .pythonWorkspaceSettings,
            languages: [Language(extensions: ["py", "pyw", "pyi"], languageId: "python")]
        ),
        // C family — TWO rows of one binary: the flagless fallback
        // standard is PER LANGUAGE FAMILY (a -std flag carries the
        // family, so one flat fallbackFlags list would poison the other
        // half — probed: a .c file under [-std=c++20] gets BOTH the
        // driver error "not allowed with 'C'" AND parses as C++, false
        // diagnostics on valid C). The C row needs NO fallback flags —
        // clangd's own .c default (gnu17) is already correct; the C++
        // row bumps the flagless default from gnu++17 to c++20
        // (std::ranges unresolvable otherwise), and a database entry
        // (cmake's CMAKE_CXX_STANDARD via CMAKE_EXPORT_COMPILE_COMMANDS)
        // always wins for both.
        Spec(
            key: "c",
            command: "clangd",
            paths: clangdPaths,
            languages: [Language(extensions: ["c"], languageId: "c")]
        ),
        Spec(
            key: "cpp",
            command: "clangd",
            paths: clangdPaths,
            fallbackFlags: ["-std=c++20"],
            languages: [
                Language(extensions: ["h", "cpp", "cc", "cxx", "hpp", "hxx"], languageId: "cpp"),
            ]
        ),
    ]

    /// The table's keyed access — the KEY is the join token of the
    /// whole wiring (this table emits it, `lspClients` is keyed by it,
    /// behavior resolves from it). nil for a key with no row
    /// (unreachable from setupLSP, where keys come from rows;
    /// defensive for future callers).
    public static func spec(forKey key: String) -> Spec? {
        all.first { $0.key == key }
    }

    /// The language entry covering the extension, with its server.
    private static func language(forExt ext: String) -> (spec: Spec, language: Language)? {
        for spec in all {
            if let language = spec.languages.first(where: { $0.extensions.contains(ext) }) {
                return (spec, language)
            }
        }
        return nil
    }

    /// The `lspClients` key owning this extension, nil when no language
    /// server is configured for it — nil short-circuits the whole
    /// pipeline (didOpen/didChange/didClose, semantic tokens,
    /// diagnostics, `gd`).
    public static func serverKey(forExt ext: String) -> String? {
        language(forExt: ext)?.spec.key
    }

    /// The `textDocument/didOpen` languageId for this extension;
    /// "plaintext" for extensions without a server.
    public static func languageId(forExt ext: String) -> String {
        language(forExt: ext)?.language.languageId ?? "plaintext"
    }

    /// Path-addressed conveniences — the extension-extraction policy
    /// (NSString pathExtension: no dot, case-sensitive, "" for none)
    /// lives with the table, not at its callers.
    public static func serverKey(forPath path: String) -> String? {
        serverKey(forExt: (path as NSString).pathExtension)
    }

    public static func languageId(forPath path: String) -> String {
        languageId(forExt: (path as NSString).pathExtension)
    }
}
