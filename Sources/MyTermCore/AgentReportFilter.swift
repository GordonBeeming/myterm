/// Native status callbacks repeat while metadata changes. Tool completion and delayed
/// hooks must not clear another question or a newer Grok prompt's attention state.
public struct AgentReportFilter: Sendable {
    private var agent: String?
    private var session: String?
    private var turn: String?
    private var pending: [String: AgentActivityReport] = [:]
    private var activeTools: [String: AgentActivityReport] = [:]
    private var last: AgentActivityReport?
    private var hasWorked = false
    private var settled = false
    private var settledAt: Double?
    private var latestSnapshotAt: Double?
    private var latestWorkStartAt: Double?

    public init() {}

    public var pendingReports: [AgentActivityReport] {
        pending.values.map { $0.replacingTurnID($0.turnID ?? turn) }
    }

    public var restorationReports: [AgentActivityReport] {
        activeTools.values.map { $0.replacingTurnID($0.turnID ?? turn) } + pendingReports
    }

    public mutating func process(_ incoming: AgentActivityReport) -> AgentActivityReport? {
        var report = incoming
        guard report.agent == "antigravity" || report.agent == "grok" else { return report }
        // Initialization callbacks have no session yet and cannot own a pane's state.
        guard report.sessionID != nil else { return nil }
        if report.agent == "antigravity", agent == report.agent, report.isStatusSnapshot,
           let captured = report.capturedAt,
           let newest = [settledAt, latestSnapshotAt, latestWorkStartAt].compactMap({ $0 }).max(), captured < newest {
            return nil
        }
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
            activeTools.removeAll()
            settled = false
        } else if let current = turn, let reported = report.turnID, current != reported {
            return nil
        } else if turn == nil {
            turn = report.turnID
        }
        if report.agent == "grok", report.turnID == nil {
            report = report.replacingTurnID(turn)
        }
        if report.agent == "antigravity", let captured = report.capturedAt {
            if let settledAt, captured < settledAt { return nil }
            if report.isStatusSnapshot {
                if let latestSnapshotAt, captured < latestSnapshotAt { return nil }
                if let latestWorkStartAt, captured < latestWorkStartAt { return nil }
                latestSnapshotAt = captured
            } else if report.activity == .finished {
                if let latestSnapshotAt, captured < latestSnapshotAt { return nil }
                if let latestWorkStartAt, captured < latestWorkStartAt { return nil }
            }
        }
        switch report.activity {
        case .awaitingInput:
            if report.isStatusSnapshot && settled { return nil }
            settled = false
            hasWorked = true
            if let request = report.toolRequestID, pending.count < 4096 { pending[request] = report }
        case .working:
            let freshStatus = report.agent == "antigravity" && report.isStatusSnapshot
                && report.capturedAt.map { $0 > (settledAt ?? -1) } == true
            if settled && !report.beginsTurn && !report.isWorkStart && !freshStatus { return nil }
            if !report.isStatusSnapshot || freshStatus { settled = false }
            if report.isWorkStart, let captured = report.capturedAt {
                latestWorkStartAt = max(latestWorkStartAt ?? captured, captured)
            }
            hasWorked = true
            if let call = report.toolCallID {
                if report.isWorkStart {
                    if activeTools.count < 4096 { activeTools[call] = report }
                } else {
                    activeTools.removeValue(forKey: call)
                }
            }
            if !report.isWorkStart, let request = report.toolRequestID,
               !activeTools.values.contains(where: { $0.toolRequestID == request }) {
                pending.removeValue(forKey: request)
            }
            guard pending.isEmpty else { return nil }
        case .ready:
            pending.removeAll()
            activeTools.removeAll()
            hasWorked = false
            settled = false
            turn = nil
            settledAt = nil
            latestSnapshotAt = nil
            latestWorkStartAt = nil
        case .finished, .exited:
            pending.removeAll()
            activeTools.removeAll()
            if report.activity == .finished {
                settled = true
                settledAt = report.capturedAt
                if !report.isStatusSnapshot { hasWorked = true }
                if report.isStatusSnapshot && !hasWorked { report = report.replacingActivity(.ready) }
            }
        }
        guard last != report else { return nil }
        last = report
        return report
    }
}
