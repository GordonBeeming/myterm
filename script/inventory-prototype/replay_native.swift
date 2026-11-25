// Replay sanitized real native captures through the current production parser/filter.
import Foundation
import MyTermCore

struct Capture: Decodable {
    var name: String
    var payloads: [String]
}

do {
    let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    var results: [[String: Any]] = []
    for capture in captures {
        var filter = AgentReportFilter()
        var states: [String] = []
        var accepted = 0
        for payload in capture.payloads {
            guard let report = AgentActivityMarker.report(fromPayload: payload) else {
                throw NSError(domain: "NativeCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Production parser rejected captured report in \(capture.name)"])
            }
            accepted += 1
            if let filtered = filter.process(report) { states.append(filtered.activity.rawValue) }
        }
        results.append(["name": capture.name, "parsedReports": accepted, "filteredStates": states,
                        "pendingRequests": filter.pendingReports.count,
                        "scope": "Recorded native bytes through current production parser/filter. Parsing success is not a lifecycle contract pass."])
    }
    try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]))
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
