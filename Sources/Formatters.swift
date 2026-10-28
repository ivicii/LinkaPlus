import Foundation

/// Date parsing/formatting helpers for the mixed timestamp formats the API uses:
/// ISO-8601 (location_update_time, createdAt) and epoch strings (activity timestamp).
enum DateUtils {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    /// Epoch seconds or milliseconds in a string.
    static func parseEpoch(_ s: String?) -> Date? {
        guard let s, let v = Double(s) else { return nil }
        let seconds = v > 1e11 ? v / 1000 : v
        return Date(timeIntervalSince1970: seconds)
    }

    /// Try ISO first, then epoch.
    static func parseAny(_ s: String?) -> Date? {
        parseISO(s) ?? parseEpoch(s)
    }

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()

    private static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.unitsStyle = .full
        return f
    }()

    static func absolute(_ d: Date) -> String { display.string(from: d) }
    static func relative(_ d: Date) -> String { relativeFmt.localizedString(for: d, relativeTo: Date()) }

    /// "27 okt 2026, 22:35 (2 dagen geleden)"
    static func absoluteWithRelative(_ d: Date) -> String {
        "\(absolute(d)) (\(relative(d)))"
    }

    private static let hmFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "22:35"
    static func timeHM(_ d: Date) -> String { hmFmt.string(from: d) }
}
