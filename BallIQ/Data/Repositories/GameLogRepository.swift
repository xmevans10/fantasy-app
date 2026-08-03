import Foundation

/// The career game log — every finished session, in order.
///
/// ## Why a file, and why this file
///
/// **Not UserDefaults.** `ratingHistory.<sport>` already demonstrates the failure mode: it holds a
/// `[RatingPoint]` array that is decoded, appended to, and re-encoded *in full* on every single
/// completion. This log carries 10-50x the payload per row and grows without a natural bound, so
/// the same pattern would mean re-serialising the player's entire history on every game they
/// finish, forever.
///
/// **Not `DiskCache`.** That writes to `.cachesDirectory`, which the OS may purge at any time under
/// storage pressure — its own doc comment says losing a file there is "a latency regression, never
/// a correctness bug". That is exactly true for puzzle payloads and exactly false here: a career
/// log that can silently evaporate is worse than no career log, because the player only discovers
/// it when their records are gone.
///
/// So: append-only JSON Lines in `.applicationSupportDirectory`, which is backed up and not
/// purgeable. One line per session means an append is a seek-to-end and a short write rather than a
/// full rewrite, and a single corrupt line costs one session instead of the whole history (see
/// `decodeLines`, which skips what it can't parse rather than throwing the file away).
///
/// Encode/decode runs off the main actor via `Task.detached`, mirroring `DiskCache`'s reasoning —
/// callers are `@MainActor` and a few thousand rows are enough to jank a frame.
protocol GameLogRepository {
    /// Chronological, oldest first.
    func all() async -> [GameResult]
    func append(_ result: GameResult) async
    /// Union by `id`, for restoring the server mirror on sign-in. Existing local rows win, since
    /// they may carry fields a round trip could have dropped.
    func merge(_ results: [GameResult]) async
}

actor LocalGameLogRepository: GameLogRepository {

    static let fileName = "gamelog.v1.jsonl"
    /// Sibling holding lifetime totals for sessions that have aged out of `fileName`, so trimming
    /// can never make "games played" or "cards judged" go backwards.
    static let rollupFileName = "gamelog-rollup.v1.json"

    /// Rows retained in full. ~7 years at two sessions a day; past this the oldest fold into the
    /// rollup. Generous on purpose — the whole point of the feature is a long memory.
    static let retainedRows = 5_000

    /// Test seam, same shape and same reason as `DiskCache.directoryOverride`: hosted unit tests
    /// run inside the real BallIQ.app process, so without a redirect a test that appends a row
    /// would write into the user's actual career history.
    nonisolated(unsafe) static var directoryOverride: URL?

    /// Loaded once, then authoritative — every append updates memory and the file together, so no
    /// read after the first ever touches disk.
    private var cached: [GameResult]?

    // MARK: - Reading

    func all() async -> [GameResult] {
        if let cached { return cached }
        let rows = await Self.loadFromDisk()
        cached = rows
        return rows
    }

    // MARK: - Writing

    func append(_ result: GameResult) async {
        var rows = await all()
        rows.append(result)
        cached = rows
        await Self.appendLine(result)
        if rows.count > Self.retainedRows { await trim() }
    }

    func merge(_ results: [GameResult]) async {
        let rows = await all()
        var byID = [UUID: GameResult]()
        // Incoming first so local wins a collision.
        for row in results { byID[row.id] = row }
        for row in rows { byID[row.id] = row }
        guard byID.count != rows.count else { return }   // nothing new; don't rewrite the file
        let merged = byID.values.sorted { $0.playedAt < $1.playedAt }
        cached = merged
        await Self.rewrite(merged)
    }

    /// Folds the oldest rows into the rollup and rewrites the file with the newest `retainedRows`.
    private func trim() async {
        guard let rows = cached, rows.count > Self.retainedRows else { return }
        let evicted = rows.prefix(rows.count - Self.retainedRows)
        let kept = Array(rows.suffix(Self.retainedRows))
        var rollup = await Self.loadRollup()
        rollup.fold(Array(evicted))
        cached = kept
        await Self.writeRollup(rollup)
        await Self.rewrite(kept)
    }

    /// Lifetime totals for sessions no longer retained in full.
    func rollup() async -> GameLogRollup { await Self.loadRollup() }

    // MARK: - Account deletion

    /// Removes the log entirely.
    ///
    /// `RepositoryContainer.wipeLocalUserData()` must call this. That method sweeps UserDefaults
    /// key prefixes and calls `DiskCache.purge()`, neither of which reaches Application Support —
    /// so without this a deleted account would leave its complete play history sitting on disk.
    /// That's an App Store 5.1.1(v) problem, not merely a bug.
    static func wipe() {
        for name in [fileName, rollupFileName] {
            guard let url = fileURL(for: name) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Drops the in-memory copy so the next read re-hits disk. Needed after `wipe()` on a live
    /// instance, and by tests that swap `directoryOverride` between cases.
    func invalidate() { cached = nil }

    // MARK: - Disk

    private static func fileURL(for name: String) -> URL? {
        let base = directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        // Application Support is not guaranteed to exist on a fresh install, unlike Caches.
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(name)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func loadFromDisk() async -> [GameResult] {
        await Task.detached(priority: .utility) {
            guard let url = fileURL(for: fileName),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return decodeLines(text)
        }.value
    }

    /// One unparseable line costs that session, not the file. A partial final line is the expected
    /// case after a crash mid-append, and it must not take the whole history with it.
    private static func decodeLines(_ text: String) -> [GameResult] {
        let decoder = decoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(GameResult.self, from: data)
        }
    }

    private static func appendLine(_ result: GameResult) async {
        await Task.detached(priority: .utility) {
            guard let url = fileURL(for: fileName),
                  var data = try? encoder().encode(result) else { return }
            data.append(0x0A)   // \n
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)   // first ever row
            }
        }.value
    }

    private static func rewrite(_ rows: [GameResult]) async {
        await Task.detached(priority: .utility) {
            guard let url = fileURL(for: fileName) else { return }
            let encoder = encoder()
            var out = Data()
            for row in rows {
                guard var data = try? encoder.encode(row) else { continue }
                data.append(0x0A)
                out.append(data)
            }
            try? out.write(to: url, options: .atomic)
        }.value
    }

    private static func loadRollup() async -> GameLogRollup {
        await Task.detached(priority: .utility) {
            guard let url = fileURL(for: rollupFileName), let data = try? Data(contentsOf: url),
                  let rollup = try? decoder().decode(GameLogRollup.self, from: data)
            else { return GameLogRollup() }
            return rollup
        }.value
    }

    private static func writeRollup(_ rollup: GameLogRollup) async {
        await Task.detached(priority: .utility) {
            guard let url = fileURL(for: rollupFileName),
                  let data = try? encoder().encode(rollup) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }
}

/// Lifetime totals for sessions that have aged out of the retained log, so headline counters stay
/// monotonic across a trim. Deliberately only the handful of stats that are pure sums — anything
/// needing the distribution (medians, most-missed player) is honestly scoped to retained rows.
struct GameLogRollup: Codable, Equatable {
    var games = 0
    var correct = 0
    var attempted = 0
    var perfects = 0
    var xp = 0
    var durationMs = 0

    mutating func fold(_ rows: [GameResult]) {
        for row in rows {
            games += 1
            correct += row.correct
            attempted += row.attempted
            if row.perfect { perfects += 1 }
            xp += row.xpEarned
            durationMs += row.durationMs ?? 0
        }
    }
}
