import EventKit
import AppKit

/// Upcoming calendar events for the "Events" main page (EventKit).
final class CalendarService {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        var subtitle: String {
            let f = DateFormatter()
            f.dateFormat = "EEE d MMM, HH:mm"
            return "\(f.string(from: startDate)) – \(f.string(from: endDate))"
        }
    }

    private let store = EKEventStore()
    private var authorized = false

    func requestAccess(completion: (() -> Void)? = nil) {
        let finish: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                self?.authorized = granted
                completion?()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in finish(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in finish(granted) }
        }
    }

    func upcomingEvents(withinMinutes minutes: Int) -> [Event] {
        guard authorized else { return [] }
        let start = Date()
        let end = start.addingTimeInterval(TimeInterval(minutes) * 60)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        return events
            .sorted { $0.startDate < $1.startDate }
            .prefix(5)
            .map {
                Event(id: $0.calendarItemIdentifier,
                      title: $0.title ?? "(untitled)",
                      startDate: $0.startDate,
                      endDate: $0.endDate)
            }
    }

    static func openInCalendar() {
        NSWorkspace.shared.open(URL(string: "ical://") ?? URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}
