import Foundation

/// Parses relative time expressions out of a question ("yesterday afternoon",
/// "this morning", "2 hours ago", "last week") into a date range used to
/// post-filter search results by their captured_at metadata.
struct TimeScope {
    var start: Date
    var end: Date

    static func parse(_ q: String, now: Date = Date()) -> TimeScope? {
        let s = q.lowercased()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        func dayRange(_ offset: Int) -> (Date, Date) {
            let start = cal.date(byAdding: .day, value: offset, to: today)!
            return (start, cal.date(byAdding: .day, value: 1, to: start)!)
        }

        var base: (Date, Date)?
        if s.contains("yesterday") { base = dayRange(-1) }
        else if s.contains("today") || s.contains("this morning") || s.contains("this afternoon") || s.contains("this evening") || s.contains("tonight") { base = dayRange(0) }
        else if s.contains("last week") {
            let start = cal.date(byAdding: .day, value: -7, to: today)!
            base = (start, now)
        } else if s.contains("this week") {
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            base = (start, now)
        }

        // "N hours ago" / "an hour ago"
        if let match = s.range(of: #"(\d+|an?)\s+hours?\s+ago"#, options: .regularExpression) {
            let token = String(s[match]).split(separator: " ").first.map(String.init) ?? "1"
            let n = Int(token) ?? 1
            let center = cal.date(byAdding: .hour, value: -n, to: now)!
            return TimeScope(start: center.addingTimeInterval(-45 * 60), end: center.addingTimeInterval(45 * 60))
        }
        if let match = s.range(of: #"(\d+)\s+minutes?\s+ago"#, options: .regularExpression) {
            let n = Int(s[match].split(separator: " ").first ?? "10") ?? 10
            let center = cal.date(byAdding: .minute, value: -n, to: now)!
            return TimeScope(start: center.addingTimeInterval(-15 * 60), end: center.addingTimeInterval(15 * 60))
        }

        guard var (start, end) = base else { return nil }

        // Narrow to part of day when mentioned.
        if s.contains("morning") {
            start = cal.date(bySettingHour: 5, minute: 0, second: 0, of: start)!
            end = cal.date(bySettingHour: 12, minute: 0, second: 0, of: start)!
        } else if s.contains("afternoon") {
            start = cal.date(bySettingHour: 12, minute: 0, second: 0, of: start)!
            end = cal.date(bySettingHour: 18, minute: 0, second: 0, of: start)!
        } else if s.contains("evening") || s.contains("tonight") {
            start = cal.date(bySettingHour: 18, minute: 0, second: 0, of: start)!
            end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: start)!
        }
        return TimeScope(start: start, end: end)
    }

    func contains(iso: String?) -> Bool {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return false }
        return date >= start && date <= end
    }
}
