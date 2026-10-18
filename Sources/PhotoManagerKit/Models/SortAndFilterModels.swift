import Foundation

/// Options for sorting photos and videos in list and grid views.
public enum AssetSortOrder: String, CaseIterable, Identifiable, Sendable {
    case latest = "Latest"
    case oldest = "Oldest"
    case largest = "Largest"
    case smallest = "Smallest"
    
    public var id: String { rawValue }
    public var title: String { rawValue }
    
    public var sfSymbol: String {
        switch self {
        case .latest: return "arrow.down"
        case .oldest: return "arrow.up"
        case .largest: return "arrow.down.circle"
        case .smallest: return "arrow.up.circle"
        }
    }
}

/// Options for filtering photos and videos by capture date.
public enum AssetTimeFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case last7Days = "Last 7 days"
    case last30Days = "Last 30 days"
    case thisYear = "This year"
    case lastYear = "Last year"
    
    public var id: String { rawValue }
    
    /// Evaluates if the asset's creationDate satisfies the time period.
    public func matches(date: Date?) -> Bool {
        guard self != .all else { return true }
        guard let date = date else { return false }
        
        let cal = Calendar.current
        let now = Date()
        
        switch self {
        case .all:
            return true
            
        case .last7Days:
            guard let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now) else { return false }
            return date >= sevenDaysAgo
            
        case .last30Days:
            guard let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: now) else { return false }
            return date >= thirtyDaysAgo
            
        case .thisYear:
            guard let startOfYear = cal.date(from: cal.dateComponents([.year], from: now)) else { return false }
            return date >= startOfYear
            
        case .lastYear:
            let currentYear = cal.component(.year, from: now)
            guard let startOfThisYear = cal.date(from: DateComponents(year: currentYear, month: 1, day: 1)),
                  let startOfLastYear = cal.date(from: DateComponents(year: currentYear - 1, month: 1, day: 1)) else {
                return false
            }
            return date >= startOfLastYear && date < startOfThisYear
        }
    }
}
