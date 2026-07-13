import Foundation

/// Minimal disk-backed cache for the two payloads expensive enough to dominate cold-launch
/// latency (the arcade catalog pool, ~1MB, and daily puzzle rows) — see BALLIQ_SPEC §9
/// backlog #3. Callers own their own freshness policy (a flat TTL for the catalog, "same
/// UTC day" for daily puzzles), so this only persists a value alongside the moment it was
/// written and hands back both. Encode/decode runs off the main actor via `Task.detached`
/// since `PlayerSeasonCatalog` is `@MainActor` and these payloads are large enough to jank
/// launch if decoded inline.
enum DiskCache {
    struct Entry<T> {
        let value: T
        let writtenAt: Date
    }

    static func read<T: Codable>(_ type: T.Type, key: String) async -> Entry<T>? {
        await Task.detached(priority: .utility) {
            guard let url = cacheURL(for: key), let data = try? Data(contentsOf: url),
                  let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else { return nil }
            return Entry(value: envelope.value, writtenAt: envelope.writtenAt)
        }.value
    }

    /// Only ever call with genuinely-fetched remote data — writing the bundled offline
    /// fallback here would let a single offline launch poison every launch after it with
    /// stale, deliberately-trimmed sample data. `writtenAt` defaults to now; tests override
    /// it to plant an already-expired entry without sleeping real time.
    static func write<T: Codable>(_ value: T, key: String, writtenAt: Date = Date()) async {
        await Task.detached(priority: .utility) {
            guard let url = cacheURL(for: key),
                  let data = try? JSONEncoder().encode(Envelope(writtenAt: writtenAt, value: value)) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }

    /// Caches directory can be purged by the OS at any time — every caller here already
    /// treats a miss as "go fetch", so losing the file is a latency regression, never a
    /// correctness bug.
    private static func cacheURL(for key: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(key).json")
    }

    private struct Envelope<T: Codable>: Codable {
        let writtenAt: Date
        let value: T
    }
}
