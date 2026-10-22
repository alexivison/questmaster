import Foundation
import QuestmasterCore

/// Asks serve's dir_suggest for a path field's dropdown rows (New Session, New Quest), dropping answers
/// to a query the field has since moved past.
@MainActor
final class PathSuggester {
    static let maxRows = 3
    private static let debounceInterval: Duration = .milliseconds(175)

    private let client: ServeDirectorySuggesting?
    private var requestID = 0
    private var debounceTask: Task<Void, Never>?

    init(client: ServeDirectorySuggesting?) {
        self.client = client
    }

    /// `recentsOnly`: the recent paths alone (⌃r). An empty answer falls back to the recents, and with
    /// no recents either, a typed path suggests itself.
    func request(_ query: String, recentsOnly: Bool = false, apply: @escaping ([String]) -> Void) {
        debounceTask?.cancel()
        requestID += 1
        let id = requestID
        client?.suggestDirectories(query: query) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.requestID == id else {
                    return
                }
                var values: [String] = []
                if case .success(let response) = result {
                    values = recentsOnly ? response.recents : response.suggestions
                    if values.isEmpty {
                        values = response.recents
                    }
                }
                apply(Self.rows(values, query: query))
            }
        }
    }

    /// Waits for typing to pause. The answer in flight is dropped at once, so Tab can't complete from
    /// rows for the path before this keystroke; the caller clears the rows it shows.
    func requestDebounced(_ query: String, apply: @escaping ([String]) -> Void) {
        debounceTask?.cancel()
        requestID += 1
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else {
                return
            }
            self?.request(query, apply: apply)
        }
    }

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        requestID += 1
    }

    private static func rows(_ values: [String], query: String) -> [String] {
        if !values.isEmpty {
            return Array(values.prefix(maxRows))
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? [] : [clean]
    }

    /// Tab without a highlighted row: completes the last component from the directories on disk, to the
    /// common prefix of several matches, or the one match plus "/".
    static func localCompletion(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let directory: String
        let partial: String
        if expanded.hasSuffix("/") || expanded.isEmpty {
            directory = expanded.isEmpty ? "." : expanded
            partial = ""
        } else {
            directory = (expanded as NSString).deletingLastPathComponent
            partial = (expanded as NSString).lastPathComponent
        }
        guard let names = (try? FileManager.default.contentsOfDirectory(atPath: directory))?
            .filter({ name in
                var isDir: ObjCBool = false
                return name.hasPrefix(partial)
                    && FileManager.default.fileExists(
                        atPath: URL(fileURLWithPath: directory).appendingPathComponent(name).path,
                        isDirectory: &isDir
                    )
                    && isDir.boolValue
            })
            .sorted(), !names.isEmpty else {
            return raw
        }
        let chosen = names.count == 1 ? names[0] : commonPrefix(names)
        guard !chosen.isEmpty else {
            return raw
        }
        return URL(fileURLWithPath: directory).appendingPathComponent(chosen).path + (names.count == 1 ? "/" : "")
    }

    private static func commonPrefix(_ values: [String]) -> String {
        guard var prefix = values.first else {
            return ""
        }
        for value in values.dropFirst() {
            while !value.hasPrefix(prefix) {
                prefix.removeLast()
                if prefix.isEmpty {
                    return ""
                }
            }
        }
        return prefix
    }
}
