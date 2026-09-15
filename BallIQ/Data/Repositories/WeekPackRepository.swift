import Foundation

/// Reads published Week Packs (`packs` + `pack_items`). Remote-only, like `CohortRepository`:
/// a pack is about last week, so there is no bundled offline copy worth shipping.
///
/// Two small requests per Home load: the packs released inside the current window (RLS already
/// hides drafts), then those packs' items. Visibility by release day is decided here on the
/// device-local day, the same rule `RemotePuzzleRepository.released` applies to dailies, because
/// the server cannot know what day it is for the reader.
final class WeekPackRepository {
    private let client: SupabaseClient?
    private let decoder = JSONDecoder()

    init(client: SupabaseClient?) { self.client = client }

    func currentPacks(today: String = PuzzleStore.localDayString()) async -> [WeekPack] {
        #if DEBUG
        if let path = DebugLaunch.weekPackFixture {
            return WeekPackSchedule.current(Self.fixture(path: path, decoder: decoder), today: today)
        }
        #endif
        guard let client else { return [] }
        let packQuery = [
            URLQueryItem(name: "select", value: "id,sport,label,release_date"),
            URLQueryItem(name: "release_date", value: "lte.\(today)"),
            URLQueryItem(name: "release_date", value: "gt.\(WeekPackSchedule.windowStart(today: today))"),
            // Only sports this build can decode, or one unknown sport empties the whole list.
            URLQueryItem(name: "sport", value: Sport.decodableFilterValue),
            URLQueryItem(name: "order", value: "release_date.desc"),
        ]
        guard let packs: [Lossy<WeekPackRow>] = try? await client.select(
                "packs", query: packQuery, decoder: decoder) else { return [] }
        let rows = packs.compactMap(\.value)
        guard !rows.isEmpty else { return [] }
        let ids = rows.map(\.id).joined(separator: ",")
        let itemQuery = [
            URLQueryItem(name: "select", value: "id,pack_id,ordinal,role,format,content"),
            URLQueryItem(name: "pack_id", value: "in.(\(ids))"),
            URLQueryItem(name: "order", value: "ordinal"),
        ]
        let items: [Lossy<WeekPackItemRow>] = (try? await client.select(
            "pack_items", query: itemQuery, decoder: decoder)) ?? []
        return WeekPackSchedule.current(
            WeekPackSchedule.assemble(packs: rows, items: items.compactMap(\.value)), today: today)
    }

    #if DEBUG
    private struct Fixture: Decodable {
        let packs: [Lossy<WeekPackRow>]
        let items: [Lossy<WeekPackItemRow>]
    }

    private static func fixture(path: String, decoder: JSONDecoder) -> [WeekPack] {
        guard let data = FileManager.default.contents(atPath: path),
              let fixture = try? decoder.decode(Fixture.self, from: data) else {
            print("[weekpack] fixture unreadable at \(path)")
            return []
        }
        return WeekPackSchedule.assemble(packs: fixture.packs.compactMap(\.value),
                                         items: fixture.items.compactMap(\.value))
    }
    #endif
}
