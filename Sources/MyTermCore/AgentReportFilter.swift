/// Native status callbacks repeat while metadata changes. Tool completion and delayed
/// hooks must not clear another question or a newer Grok prompt's attention state.
public struct AgentReportFilter: Sendable {
    private var agent: String?
    private var session: String?
    private var turn: String?
    private var pending: [String: AgentActivityReport] = [:]
    private var last: AgentActivityReport?
    private var hasWorked = false
    private var settled = false

    public init() {}

    public var pendingReports: [AgentActivityReport] { Array(pending.values) }

    public mutating func process(_ incoming: AgentActivityReport) -> AgentActivityReport? {
        var report = incoming
        guard report.agent == "antigravity" || report.agent == "grok" else { return report }
        // Initialization callbacks have no session yet and cannot own a pane's state.
        guard report.sessionID != nil else { return nil }
        // Only the parent TUI runs the status callback. In-process child hook payloads
        // may carry a different conversation without any explicit subagent flag.
        if report.agent == "antigravity", agent == report.agent, let session,
           report.sessionID != session, !report.isStatusSnapshot { return nil }
        if report.agent != agent || report.sessionID != session {
            self = Self()
            agent = report.agent
            session = report.sessionID
        }
        if report.beginsTurn {
            turn = report.turnID
            pending.removeAll()
            settled = false
        } else if let current = turn, let reported = report.turnID, current != reported {
            return nil
        } else if turn == nil {
            turn = report.turnID
        }
        switch report.activity {
        case .awaitingInput:
            if report.isStatusSnapshot && settled { return nil }
            settled = false
            hasWorked = true
            if let request = report.toolRequestID, pending.count < 4096 { pending[request] = report }
        case .working:
            if settled && (report.isStatusSnapshot || report.agent == "grok") && !report.beginsTurn { return nil }
            if !report.isStatusSnapshot { settled = false }
            hasWorked = true
            if let request = report.toolRequestID { pending.removeValue(forKey: request) }
            guard pending.isEmpty else { return nil }
        case .ready:
            pending.removeAll()
            hasWorked = false
            settled = false
            turn = nil
        case .finished, .exited:
            pending.removeAll()
            if report.activity == .finished {
                settled = true
                if report.isStatusSnapshot && !hasWorked { report = report.replacingActivity(.ready) }
            }
        }
        guard last != report else { return nil }
        last = report
        return report
    }
}
