import Foundation
import UserNotifications

/// A user-defined intention about their time.
///  - `.limit`  — don't spend MORE than `minutes` on `target` today.
///  - `.focus`  — spend AT LEAST `minutes` on `target` today.
/// `target` is a time-tracker label: an app display name ("Slack") or a site
/// host ("substack.com") — exactly what `AppSpan.app` holds.
enum GoalKind: String, Codable, CaseIterable {
    case limit
    case focus
    var title: String { self == .limit ? "Limit" : "Focus" }
    var verb: String { self == .limit ? "Stay under" : "Reach at least" }
}

struct Goal: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: GoalKind
    var target: String
    var minutes: Int
    var createdAt: Date

    var isSite: Bool { target.contains(".") && !target.contains(" ") }
    var domain: String? { isSite ? target : nil }
}

/// Owns the goal list, evaluates it against today's tracked time, and fires
/// notifications + surfaces in-app breaches. Notifications fire once per day
/// per goal; breaches can be acknowledged to dismiss the in-app banner.
@MainActor
final class GoalStore: ObservableObject {
    static let shared = GoalStore()

    @Published private(set) var goals: [Goal] = []
    /// Limit goals currently over budget and not yet acknowledged today.
    @Published private(set) var activeBreaches: [Goal] = []
    /// Live progress (0…∞) per goal id, from the last evaluation.
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var secondsToday: [UUID: Double] = [:]

    private let d = UserDefaults.standard
    private let goalsKey = "clemGoals"
    private let stateKey = "clemGoalState" // notified/acknowledged, per day

    private var notified: Set<String> = []      // "<id>" once fired today
    private var acknowledged: Set<String> = []   // "<id>" dismissed today
    private var stateDay = ""

    init() {
        load()
        Task { await requestAuthIfNeeded() }
    }

    // MARK: CRUD

    func add(_ goal: Goal) { goals.append(goal); persistGoals(); Task { await requestAuthIfNeeded() } }
    func delete(_ goal: Goal) {
        goals.removeAll { $0.id == goal.id }
        activeBreaches.removeAll { $0.id == goal.id }
        persistGoals()
    }
    func update(_ goal: Goal) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[i] = goal
        // Editing resets its fired/ack state so it re-evaluates cleanly.
        notified.remove(goal.id.uuidString)
        acknowledged.remove(goal.id.uuidString)
        persistGoals(); persistState()
    }

    func acknowledge(_ goal: Goal) {
        acknowledged.insert(goal.id.uuidString)
        activeBreaches.removeAll { $0.id == goal.id }
        persistState()
    }

    // MARK: evaluation

    /// Called from the engine's poll loop with today's per-app/site breakdown.
    func evaluate(appTimes: [AppSpan]) {
        rolloverIfNeeded()
        var breaches: [Goal] = []
        var prog: [UUID: Double] = [:]
        var secs: [UUID: Double] = [:]

        for goal in goals {
            let seconds = Self.seconds(for: goal, in: appTimes)
            let threshold = Double(goal.minutes * 60)
            secs[goal.id] = seconds
            prog[goal.id] = threshold > 0 ? seconds / threshold : 0
            let met = threshold > 0 && seconds >= threshold
            guard met else { continue }
            let key = goal.id.uuidString

            switch goal.kind {
            case .limit:
                if !acknowledged.contains(key) { breaches.append(goal) }
                if !notified.contains(key) {
                    notified.insert(key)
                    notify(
                        title: "Time's up on \(goal.target)",
                        body: "You've passed your \(goal.minutes)-min limit for today."
                    )
                }
            case .focus:
                if !notified.contains(key) {
                    notified.insert(key)
                    notify(
                        title: "Goal reached — \(goal.target)",
                        body: "You hit your \(goal.minutes) min of focused time. Nice."
                    )
                }
            }
        }
        activeBreaches = breaches
        progress = prog
        secondsToday = secs
        persistState()
    }

    // MARK: notifications

    private func requestAuthIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: persistence

    private func today() -> String { String(ISO8601DateFormatter().string(from: Date()).prefix(10)) }

    private func rolloverIfNeeded() {
        let t = today()
        if stateDay != t {
            stateDay = t
            notified.removeAll()
            acknowledged.removeAll()
            activeBreaches.removeAll()
            persistState()
        }
    }

    private func load() {
        if let data = d.data(forKey: goalsKey),
           let decoded = try? JSONDecoder().decode([Goal].self, from: data) {
            goals = decoded
        }
        stateDay = d.string(forKey: stateKey + ".day") ?? today()
        notified = Set(d.stringArray(forKey: stateKey + ".notified") ?? [])
        acknowledged = Set(d.stringArray(forKey: stateKey + ".ack") ?? [])
        if stateDay != today() { rolloverIfNeeded() }
    }

    private func persistGoals() {
        if let data = try? JSONEncoder().encode(goals) { d.set(data, forKey: goalsKey) }
    }
    private func persistState() {
        d.set(stateDay, forKey: stateKey + ".day")
        d.set(Array(notified), forKey: stateKey + ".notified")
        d.set(Array(acknowledged), forKey: stateKey + ".ack")
    }

    static func seconds(for goal: Goal, in appTimes: [AppSpan]) -> Double {
        let target = goal.target.lowercased()
        if let exact = appTimes.first(where: { $0.app.lowercased() == target }) {
            return exact.seconds
        }
        let matches = appTimes.filter { span in
            let app = span.app.lowercased()
            if goal.isSite {
                return app == target
                    || app.hasSuffix(".\(target)")
                    || target.hasSuffix(".\(app)")
                    || app.contains(target)
            }
            return app.contains(target) || target.contains(app)
        }
        return matches.map(\.seconds).max() ?? 0
    }
}
