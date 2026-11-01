import Testing
import SwimCore

/// LSPServers — THE single wiring table (routing + launch data + behavior
/// in one row per server). The fixtures pin the whole table: the
/// ext → (server, languageId) map, the unrouted boundary, extension
/// uniqueness across rows, the C-family sync with the tokenizer's
/// vocabulary, launch-data sanity, keyed access, and the product
/// decisions (clangd's -std=c++20 fallback, python's behavior row).
@Suite struct LSPServersTests {

    /// The complete routing expectation table: (ext, serverKey, languageId).
    private static let routing: [(ext: String, key: String, id: String)] = [
        ("swift", "swift", "swift"),
        ("cs", "csharp", "csharp"),
        ("csx", "csharp", "csharp"),
        ("go", "go", "go"),
        ("rs", "rust", "rust"),
        ("sh", "bash", "shellscript"),
        ("bash", "bash", "shellscript"),
        ("py", "python", "python"),
        ("pyw", "python", "python"),
        ("pyi", "python", "python"),
        ("c", "c", "c"),
        // Headers parse as C++ in the flagless fallback — the superset-
        // safe choice (a .h with classes/templates must not parse as
        // C/ObjC; plain C headers survive C++ mode). See LSPServers.
        ("h", "cpp", "cpp"),
        ("cpp", "cpp", "cpp"),
        ("cc", "cpp", "cpp"),
        ("cxx", "cpp", "cpp"),
        ("hpp", "cpp", "cpp"),
        ("hxx", "cpp", "cpp"),
    ]

    @Test func wholeRoutingTable() {
        for (ext, key, id) in Self.routing {
            #expect(LSPServers.serverKey(forExt: ext) == key, "serverKey(\(ext))")
            #expect(LSPServers.languageId(forExt: ext) == id, "languageId(\(ext))")
        }
    }

    /// The table's extension set is exactly the fixture's — nothing
    /// routed beyond what is pinned, nothing pinned beyond what routes.
    @Test func tableExtensionsAreExactlyTheFixture() {
        let tableExts = LSPServers.all.flatMap { $0.languages.flatMap(\.extensions) }
        #expect(Set(tableExts) == Set(Self.routing.map(\.ext)))
    }

    /// An extension in two rows would make routing order-dependent —
    /// nondeterministic. Pinned: every extension belongs to exactly one
    /// server (and one language of it).
    @Test func everyExtensionBelongsToExactlyOneServer() {
        let all = LSPServers.all.flatMap { $0.languages.flatMap(\.extensions) }
        #expect(Set(all).count == all.count)
    }

    /// Everything unrouted — near-family spellings the table
    /// deliberately does not claim (hh, ObjC .m/.mm, upper-case .C/.H —
    /// every extension table in the project is case-sensitive) — has no
    /// server and falls to the historical "plaintext" languageId.
    @Test func unroutedExtensionsHaveNoServer() {
        for ext in ["", "txt", "md", "json", "hh", "m", "mm", "C", "H", "ts", "js", "dart"] {
            #expect(LSPServers.serverKey(forExt: ext) == nil, "serverKey(\(ext))")
            #expect(LSPServers.languageId(forExt: ext) == "plaintext", "languageId(\(ext))")
        }
    }

    /// Path-addressed lookups share the extraction policy with the
    /// table (the seam Application uses): a path routes, a dotless or
    /// extension-less path does not.
    @Test func pathAddressedLookups() {
        #expect(LSPServers.serverKey(forPath: "/any/dir/main.cpp") == "cpp")
        #expect(LSPServers.serverKey(forPath: "/any/dir/main.c") == "c")
        #expect(LSPServers.languageId(forPath: "/any/dir/util.h") == "cpp")
        #expect(LSPServers.serverKey(forPath: "/any/dir/README") == nil)
        #expect(LSPServers.languageId(forPath: "/any/dir/README") == "plaintext")
    }

    /// The invariant that would have caught the historical gaps: a file
    /// that reaches a server must never be didOpened as "plaintext".
    @Test func routedExtensionsNeverPlaintext() {
        for (ext, _, _) in Self.routing {
            #expect(LSPServers.languageId(forExt: ext) != "plaintext")
        }
    }

    /// Sync with the syntax layer: every extension served by a clangd
    /// row is a C-family vocabulary word of the tokenizer — a new
    /// extension joins both tables or neither.
    @Test func cFamilySyncedWithSyntaxVocabulary() {
        let clangdExts = LSPServers.all
            .filter { $0.command == "clangd" }
            .flatMap { $0.languages.flatMap(\.extensions) }
        #expect(!clangdExts.isEmpty)
        for ext in clangdExts {
            #expect(!SyntaxTokenizer.keywords(for: ext).isEmpty,
                    "keywords(for: \(ext)) is empty — wiring and syntax tables drifted")
        }
    }

    /// Launch-data sanity: every row is discoverable (a command name and
    /// candidate paths) and keyed uniquely.
    @Test func serversAreLaunchable() {
        for spec in LSPServers.all {
            #expect(!spec.command.isEmpty)
            #expect(!spec.paths.isEmpty, "\(spec.key): no candidate paths")
            #expect(!spec.languages.isEmpty, "\(spec.key): no languages")
        }
        #expect(Set(LSPServers.all.map(\.key)).count == LSPServers.all.count)
    }

    /// Keyed access — details resolve BY KEY (the join token of the
    /// wiring): every row from its own key, a foreign key to nothing.
    @Test func detailsResolveByKey() {
        for spec in LSPServers.all {
            #expect(LSPServers.spec(forKey: spec.key) == spec, "spec(forKey: \(spec.key))")
        }
        #expect(LSPServers.spec(forKey: "nosuchserver") == nil)
    }

    /// The C-family fallback standards are product decisions pinned
    /// per row — the whole point of the family split: C++ without a
    /// database parses as c++20 (clangd's own gnu++17 default leaves
    /// std::ranges unresolvable), C carries NO fallback std (a C++ std
    /// on a .c is a driver error and parses the file as C++ — false
    /// diagnostics on valid C, probed). Changing either must be
    /// conscious.
    @Test func cFamilyFallbackStandardsPinnedPerRow() {
        #expect(LSPServers.spec(forKey: "cpp")?.fallbackFlags == ["-std=c++20"])
        #expect(LSPServers.spec(forKey: "c")?.fallbackFlags == [])
    }

    /// The typed behavior-to-row correspondence: the settings behavior
    /// belongs to the python row and to nothing else (the executable
    /// switch is exhaustive; this pins the table's side of the link).
    @Test func pythonBehaviorBelongsToThePythonRow() {
        let withBehavior = LSPServers.all.filter { $0.behavior != .none }
        #expect(withBehavior.map(\.key) == ["python"])
        #expect(withBehavior.allSatisfy { $0.behavior == .pythonWorkspaceSettings })
    }
}
