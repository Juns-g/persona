import Foundation

/// A session's dev servers to preview (#150, docs/web/preview.md「Servers」): the entries of its `.claude/launch.json`,
/// whether each is running, and what is wrong with one that cannot start. `GET /api/v1/machines/{mid}/preview/servers`.
nonisolated struct PreviewServers: Decodable, Sendable, Equatable {
    struct Server: Decodable, Sendable, Equatable, Identifiable {
        var name: String
        var port: Int?
        /// An entry that names a page instead of a command: start its server yourself.
        var url: String?
        var command: [String]?
        var env: [String: String]?
        var cwd: String?
        var listening: Bool
        var title: String?
        /// `no_name`, `no_port`, `not_local`, `no_run`, `bad_env`: it cannot be previewed.
        var problem: String?

        var id: String { name }
    }

    /// The launch.json it read, when there is one.
    var file: String?
    var servers: [Server]
    /// The file could not be read.
    var error: String?
}

/// What Start sends: the entry, the session's folder and workspace, and where its terminal tab opens.
nonisolated struct PreviewStart: Decodable, Sendable, Equatable {
    var pane: String?
    var terminal: String?
    var port: Int?
}

extension APIClient {
    func previewServers(machine: String, cwd: String) async throws -> PreviewServers {
        try await get("/api/v1/machines/\(machine)/preview/servers", query: ["cwd": cwd])
    }

    private struct PreviewStartBody: Encodable {
        var cwd: String
        var name: String
        var workspace: String
        var kind: String?
    }

    func previewStart(machine: String, cwd: String, name: String, workspace: String, kind: String?) async throws -> PreviewStart {
        try await post("/api/v1/machines/\(machine)/preview/start", body: PreviewStartBody(cwd: cwd, name: name, workspace: workspace, kind: kind), timeout: 60)
    }
}

/// One thing the preview can show: a launch.json server, or a port an Agent of the session listens on.
nonisolated struct PreviewOption: Hashable, Sendable, Identifiable {
    var name: String
    var port: Int
    /// Running now (a launch.json entry's `listening`; an Agent's port always is).
    var listening: Bool
    /// The entry can be started from here (it has a command and no problem).
    var startable: Bool
    var title: String?
    /// The words that start it, and where (for the confirmation).
    var command: String?
    var cwd: String?

    var id: String { "\(name):\(port)" }
}

nonisolated enum PreviewLogic {
    /// The usable launch.json entries (a port, no problem), then the Agents' ports no entry names: the web's
    /// `previewOptions`.
    static func options(_ res: PreviewServers?, ports: [(port: Int, title: String?)]) -> [PreviewOption] {
        var out: [PreviewOption] = []
        for s in res?.servers ?? [] where s.problem == nil {
            guard let port = s.port else { continue }
            out.append(PreviewOption(name: s.name, port: port, listening: s.listening, startable: !(s.command ?? []).isEmpty,
                                     title: s.title, command: commandLine(s), cwd: s.cwd))
        }
        for p in ports where !out.contains(where: { $0.port == p.port }) {
            out.append(PreviewOption(name: p.title ?? ":\(p.port)", port: p.port, listening: true, startable: false, title: p.title))
        }
        return out
    }

    /// The entry's command as one line, with its environment in front (`PORT=5173 npm run dev`).
    static func commandLine(_ s: PreviewServers.Server) -> String? {
        guard let command = s.command, !command.isEmpty else { return nil }
        let env = (s.env ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let words = command.map { $0.contains(" ") ? "\"\($0)\"" : $0 }
        return (env + words).joined(separator: " ")
    }

    /// The page as the computer sees it, for an element comment's `Page:`: the phone's forwarded loopback address
    /// (`http://localhost:<phone port>/…`) back to the machine's port (`http://localhost:5173/…`).
    static func machinePage(_ url: URL, machinePort: Int?) -> String {
        guard let machinePort, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        comps.host = "localhost"
        comps.port = machinePort
        return comps.string ?? url.absoluteString
    }
}
