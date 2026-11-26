// Memory pressure (voice speed round two, 17 November 2026): the slow first words after 1-15 min idle were Parakeet's
// weights paged out (app.log: 0 slow reads within 60 s of a take, 29 of 39 after 1-15 min). Under pressure the text
// model, when the user is not typing, sleeps first (~2.2 GB back) so voice keeps its pages. Pure rule; the watch is Budget.watchPressure.
import Foundation

enum PressureRules {
    enum Level: String { case normal, warning, critical }

    static let warningQuiet = 120.0   // seconds without a typing request before a warning puts the text model to sleep
    static let criticalQuiet = 15.0   // the same for critical pressure

    /// Put the text model to sleep now: not already asleep, and the user has not typed for long enough at this level.
    static func yieldText(_ level: Level, typingQuiet: Double, asleep: Bool) -> Bool {
        guard !asleep else { return false }
        switch level {
        case .critical: return typingQuiet >= criticalQuiet
        case .warning: return typingQuiet >= warningQuiet
        case .normal: return false
        }
    }
}
