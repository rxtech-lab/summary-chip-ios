import Foundation

extension EditorialHeadlines {
    /// Keep a daily edition together, preserving the server's ranking within that day.
    /// Only the current ranking window is available to the widget.
    public func widgetPicks(calendar: Calendar = .current, limit: Int = 4) -> [EditorialHeadline] {
        let persisted = editorPickIDs.map(Set.init)
        let picks = items.filter {
            ($0.kind == .summary || $0.kind == .podcast)
                && (persisted?.contains($0.id) ?? ($0.score >= 70))
        }
        guard limit > 0, let latest = picks.map(\.createdAt).max() else { return [] }
        var seen = Set<String>()
        return Array(picks.filter {
            calendar.isDate($0.createdAt, inSameDayAs: latest) && seen.insert($0.id).inserted
        }.prefix(limit))
    }
}
