import Foundation
import SwimCore

/// The effectful half of server wiring: per-server behavior AFTER start.
/// The single wiring table (LSPServers, SwimCore, tested) is the source
/// of truth; this file receives only the KEY — the join token of the
/// whole wiring — fetches the row from the table by that key, and runs
/// the exhaustive switch over the resolved Behavior. A new Behavior
/// case fails compilation here until handled; the behavior binding
/// lives on the table's row itself, so a key rename cannot detach it.
enum LSPServerSetup {

    /// Called by Application.setupLSP right after client.start — the
    /// single place a server's declared behavior runs.
    static func postStart(serverKey: String, client: LSPClient, rootPath: String) {
        let behavior = LSPServers.spec(forKey: serverKey)?.behavior ?? .none
        switch behavior {
        case .none:
            break
        case .pythonWorkspaceSettings:
            if let settings = pythonWorkspaceSettings(rootPath: rootPath) {
                client.applyWorkspaceSettings(settings)
            }
        }
    }

    /// Builds basedpyright workspace settings, pushed via
    /// workspace/didChangeConfiguration (the only settings channel
    /// basedpyright reads — its initializationOptions carries nothing but
    /// disablePullDiagnostics). The baseline matches pyright's defaults:
    /// basedpyright alone defaults typeCheckingMode to "all", whose
    /// reportUnknown*/annotation rules flood the diagnostics swim now
    /// renders; openFilesOnly keeps large monorepos from burning a CPU
    /// core analyzing files the user never opened. Returns nil when the
    /// server has its own config ([tool.basedpyright], [tool.pyright] or
    /// pyrightconfig.json) — that config must win. extraPaths is NOT
    /// forwarded: basedpyright accepts it only from the config file, so
    /// projects needing search paths write them into pyproject.toml.
    private static func pythonWorkspaceSettings(rootPath: String) -> [String: Any]? {
        if let text = try? String(contentsOfFile: rootPath + "/pyproject.toml", encoding: .utf8) {
            guard !tomlHasSection(text, "tool.basedpyright"),
                  !tomlHasSection(text, "tool.pyright"),
                  !FileManager.default.fileExists(atPath: rootPath + "/pyrightconfig.json") else { return nil }
        }
        return ["pyright": ["typeCheckingMode": "standard", "diagnosticMode": "openFilesOnly"]]
    }

    /// True when the TOML text contains the `[section]` header.
    private static func tomlHasSection(_ text: String, _ section: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), t.hasSuffix("]") else { return false }
            return t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces) == section
        }
    }
}
