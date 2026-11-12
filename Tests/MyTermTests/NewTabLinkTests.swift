@testable import MyTerm
import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import XCTest

@MainActor
final class NewTabLinkTests: XCTestCase {
    private var directory: URL!
    private var engine: LinkCapturingTerminalEngine!
    private var prompts: [NewTabLinkPrompt] = []
    private var approves = false

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "new-tab-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engine = LinkCapturingTerminalEngine()
        prompts = []
        approves = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() throws -> AppModel {
        try AppModel(
            channel: .development,
            applicationSupportDirectory: directory,
            terminalEngine: engine,
            startsTerminalProcesses: true,
            confirmNewTabLink: { [unowned self] prompt in
                prompts.append(prompt)
                return approves
            }
        )
    }

    private func link(_ query: String) throws -> URL {
        try XCTUnwrap(URL(string: "myterm://new-tab?\(query)"))
    }

    private func tabCount(_ model: AppModel, _ workspaceID: WorkspaceID) -> Int {
        model.workspaces.first(where: { $0.id == workspaceID })?.tabs.count ?? 0
    }

    // MARK: Parsing

    func testParsesEveryParameter() throws {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let request = try NewTabLinkRequest.parse(
            link("workspace=API&cwd=~/src/app&command=make%20test&token=abc"),
            homeDirectory: home
        )
        XCTAssertEqual(request.workspace, "API")
        XCTAssertEqual(request.workingDirectory?.path, "/Users/someone/src/app")
        XCTAssertEqual(request.command, "make test")
        XCTAssertEqual(request.token, "abc")
    }

    func testAnEmptyLinkAsksForAPlainTabInTheSelectedWorkspace() throws {
        let request = try NewTabLinkRequest.parse(XCTUnwrap(URL(string: "myterm://new-tab")))
        XCTAssertEqual(request, NewTabLinkRequest(workspace: nil, workingDirectory: nil, command: nil, token: nil))
    }

    func testRefusesWhatThePromptCouldNotShowHonestly() throws {
        let cases: [(String, NewTabLinkRequest.ParseError)] = [
            ("command=ls&extra=1", .unknownParameter("extra")),
            ("command=ls&command=rm", .repeatedParameter("command")),
            ("command=", .emptyParameter("command")),
            ("cwd=src", .relativeWorkingDirectory("src")),
            ("command=ls%0Arm%20-rf%20~", .unsafeCommand),
            ("command=ls%0D", .unsafeCommand),
            ("command=echo%20%E2%80%AEsafe", .unsafeCommand),
        ]
        for (query, expected) in cases {
            XCTAssertThrowsError(try NewTabLinkRequest.parse(link(query)), query) { error in
                XCTAssertEqual(error as? NewTabLinkRequest.ParseError, expected, query)
            }
        }
        XCTAssertThrowsError(try NewTabLinkRequest.parse(XCTUnwrap(URL(string: "myterm://new-tab/extra?command=ls"))))
        XCTAssertThrowsError(try NewTabLinkRequest.parse(XCTUnwrap(URL(string: "myterm://new-tab?command=ls#x"))))
    }

    // MARK: Token file

    func testTokenFileIsPrivateAndStable() throws {
        let url = directory.appending(path: "token", directoryHint: .notDirectory)
        let token = try NewTabLinkToken.loadOrCreate(at: url)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(try NewTabLinkToken.loadOrCreate(at: url), token)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertTrue(NewTabLinkToken.matches(token, token))
        XCTAssertFalse(NewTabLinkToken.matches(String(token.dropLast()) + "x", token))
        XCTAssertFalse(NewTabLinkToken.matches("", ""))
    }

    func testATokenOthersCanReadIsRefused() throws {
        let url = directory.appending(path: "token", directoryHint: .notDirectory)
        _ = try NewTabLinkToken.loadOrCreate(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try NewTabLinkToken.load(at: url))
    }

    func testASymlinkedTokenIsRefused() throws {
        let target = directory.appending(path: "elsewhere", directoryHint: .notDirectory)
        _ = try NewTabLinkToken.loadOrCreate(at: target)
        let link = directory.appending(path: "token", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try NewTabLinkToken.load(at: link))
    }

    func testAFIFOAtTheTokenPathIsRefusedWithoutWaitingForAWriter() throws {
        let url = directory.appending(path: "token", directoryHint: .notDirectory)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        // Without O_NONBLOCK this call never returns, and the test run hangs here.
        XCTAssertThrowsError(try NewTabLinkToken.load(at: url))
    }

    func testAPartTokenIsRefusedSoAShortGuessCannotMatch() throws {
        let url = directory.appending(path: "token", directoryHint: .notDirectory)
        for content in ["ab\n", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            try? FileManager.default.removeItem(at: url)
            XCTAssertTrue(FileManager.default.createFile(
                atPath: url.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]
            ))
            XCTAssertThrowsError(try NewTabLinkToken.load(at: url), content)
        }
    }

    // MARK: Opening

    func testLinksAreIgnoredUntilTheSettingIsOn() throws {
        let model = try makeModel()
        XCTAssertFalse(model.store.globalSettings.acceptsNewTabLinks, "off until the user turns it on")
        let workspaceID = model.selectedWorkspace.id
        let before = tabCount(model, workspaceID)

        model.open([try link("command=echo%20hi")])

        XCTAssertEqual(tabCount(model, workspaceID), before)
        XCTAssertTrue(prompts.isEmpty, "a link that is not allowed does not even ask")
        XCTAssertNotNil(model.errorDescription)
    }

    func testALinkWithoutATokenAsksAndADeclineOpensNothing() throws {
        let model = try makeModel()
        model.updateGlobalSettings { $0.acceptsNewTabLinks = true }
        let workspaceID = model.selectedWorkspace.id
        let before = tabCount(model, workspaceID)
        let folder = directory.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        model.open([try link("cwd=\(folder.path)&command=make%20test")])

        XCTAssertEqual(prompts, [NewTabLinkPrompt(
            workspaceTitle: model.selectedWorkspace.title,
            workingDirectory: folder.standardizedFileURL,
            command: "make test"
        )])
        XCTAssertEqual(tabCount(model, workspaceID), before)
    }

    func testAnApprovedLinkOpensTheTabInTheNamedWorkspaceAndRunsTheCommand() throws {
        let model = try makeModel()
        model.updateGlobalSettings { $0.acceptsNewTabLinks = true }
        let apiID = try model.store.createWorkspace(title: "API", selectsCreatedWorkspace: false)
        let otherID = model.selectedWorkspace.id
        XCTAssertNotEqual(apiID, otherID)
        let before = tabCount(model, apiID)
        approves = true

        model.open([try link("workspace=api&cwd=\(directory.path)&command=make%20test")])

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(tabCount(model, apiID), before + 1)
        XCTAssertEqual(model.selectedWorkspace.id, apiID, "the user sees the tab the link opened")
        XCTAssertEqual(engine.configurations.last?.initialCommand, "make test")
        XCTAssertEqual(engine.configurations.last?.workingDirectory, directory.standardizedFileURL)
    }

    func testTheWorkspaceIDAlsoNamesAWorkspace() throws {
        let model = try makeModel()
        model.updateGlobalSettings { $0.acceptsNewTabLinks = true }
        let apiID = try model.store.createWorkspace(title: "API", selectsCreatedWorkspace: false)
        approves = true

        model.open([try link("workspace=\(apiID.rawValue.uuidString)")])

        XCTAssertEqual(model.selectedWorkspace.id, apiID)
        XCTAssertNil(engine.configurations.last?.initialCommand)
    }

    func testTheRightTokenSkipsThePrompt() throws {
        let model = try makeModel()
        model.updateGlobalSettings { $0.acceptsNewTabLinks = true }
        let token = try NewTabLinkToken.loadOrCreate(at: model.newTabLinkTokenURL)
        let workspaceID = model.selectedWorkspace.id
        let before = tabCount(model, workspaceID)

        model.open([try link("command=make%20test&token=\(token)")])

        XCTAssertTrue(prompts.isEmpty)
        XCTAssertEqual(tabCount(model, workspaceID), before + 1)
        XCTAssertEqual(engine.configurations.last?.initialCommand, "make test")
    }

    func testAWrongTokenStillAsks() throws {
        let model = try makeModel()
        model.updateGlobalSettings { $0.acceptsNewTabLinks = true }
        _ = try NewTabLinkToken.loadOrCreate(at: model.newTabLinkTokenURL)
        let workspaceID = model.selectedWorkspace.id
        let before = tabCount(model, workspaceID)

        model.open([try link("command=make%20test&token=guess")])

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(tabCount(model, workspaceID), before)
    }

    func testAnUnknownWorkspaceOrMissingFolderIsReportedWithoutAsking() throws {
        let model = try makeModel()
        model.updateGlobalSettings { $0.acceptsNewTabLinks = true }

        model.open([try link("workspace=Nowhere&command=ls")])
        XCTAssertNotNil(model.errorDescription)
        model.errorDescription = nil

        model.open([try link("cwd=/definitely/not/here&command=ls")])
        XCTAssertNotNil(model.errorDescription)
        XCTAssertTrue(prompts.isEmpty)
    }

    func testTheSettingDefaultsOffAndRoundTrips() throws {
        let url = directory.appending(path: "state.json", directoryHint: .notDirectory)
        let store = try WorkspaceStore(persistenceURL: url)
        XCTAssertFalse(store.globalSettings.acceptsNewTabLinks)
        try store.updateGlobalSettings { $0.acceptsNewTabLinks = true }
        try store.flush()
        XCTAssertTrue(try WorkspaceStore(persistenceURL: url).globalSettings.acceptsNewTabLinks)
    }
}

@MainActor
private final class LinkCapturingTerminalEngine: TerminalEngine {
    private(set) var configurations: [TerminalSessionConfiguration] = []

    func makeSession(configuration: TerminalSessionConfiguration) throws -> any TerminalProcessSession {
        configurations.append(configuration)
        return LinkCapturingTerminalSession()
    }
}

@MainActor
private final class LinkCapturingTerminalSession: TerminalProcessSession {
    var isRunning = false
    var activeForegroundProcessName: String?
    var onEvent: (@MainActor (TerminalSessionEvent) -> Void)?

    func terminalView() -> NSView { NSView() }
    func start() throws { isRunning = true }
    func resize(columns: Int, rows: Int) {}
    func focus() {}
    func showFind() {}
    func terminate() { isRunning = false }
    func apply(runtimeConfiguration: TerminalRuntimeConfiguration) {}
    func contentSnapshot(maximumCharacters: Int) -> String { "" }
    func setContentChangeHandler(_ handler: (@MainActor () -> Void)?) {}
}
