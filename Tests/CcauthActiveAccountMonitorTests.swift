
import Combine
import XCTest
@testable import Codenotch

@MainActor
final class CcauthActiveAccountMonitorTests: XCTestCase {
    private final class BaseMonitor: AgentActivityMonitor {
        @Published var sessions: [AgentSession] = []
        var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }
        var starts = 0
        var stops = 0
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }

    private final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var data = CcauthFixture.statusData
        var reply: Data {
            get { lock.withLock { data } }
            set { lock.withLock { data = newValue } }
        }
        var runner: CcauthClient.Runner {
            { [self] _, _ in (reply, 0) }
        }
    }

    private let busy = AgentSession(id: "s1", name: "projeto", detail: "Working", state: .busy,
                                    waitingFor: nil, since: Date(timeIntervalSince1970: 1_800_000_000))

    private func makeClient(_ runner: Runner) -> CcauthClient {
        CcauthClient(runner: runner.runner)
    }

    func testSessionsPassOnlyWhenTheAliasIsTheActiveAccount() async throws {
        let runner = Runner()
        let client = makeClient(runner)
        _ = try await client.status()   // Gustavo ativa
        let base = BaseMonitor()
        base.sessions = [busy]
        let gustavo = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Gustavo", client: client)
        let allan = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Allan", client: client)
        XCTAssertEqual(gustavo.sessions, [busy])
        XCTAssertEqual(allan.sessions, [])
    }

    func testSessionsAreEmptyBeforeAnyStatus() {
        let base = BaseMonitor()
        base.sessions = [busy]
        let monitor = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Gustavo",
                                                 client: makeClient(Runner()))
        XCTAssertEqual(monitor.sessions, [])
    }

    func testSwitchingTheActiveAccountMovesTheSessionsBetweenMonitors() async throws {
        let runner = Runner()
        let client = makeClient(runner)
        _ = try await client.status()
        let base = BaseMonitor()
        base.sessions = [busy]
        let gustavo = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Gustavo", client: client)
        let allan = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Allan", client: client)
        var gustavoSeen: [[AgentSession]] = []
        var allanSeen: [[AgentSession]] = []
        let a = gustavo.sessionsPublisher.sink { gustavoSeen.append($0) }
        let b = allan.sessionsPublisher.sink { allanSeen.append($0) }
        defer { a.cancel(); b.cancel() }
        XCTAssertEqual(gustavoSeen.last, [busy])
        XCTAssertEqual(allanSeen.last, [])

        runner.reply = try CcauthFixture.statusData(activeClaude: "Allan")
        client.invalidate()
        _ = try await client.status()

        XCTAssertEqual(gustavoSeen.last, [])
        XCTAssertEqual(allanSeen.last, [busy])
        XCTAssertEqual(gustavo.sessions, [])
        XCTAssertEqual(allan.sessions, [busy])
    }

    func testBaseSessionChangesFlowThroughOnlyToTheActiveAlias() async throws {
        let client = makeClient(Runner())
        _ = try await client.status()
        let base = BaseMonitor()
        let gustavo = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Gustavo", client: client)
        let allan = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Allan", client: client)
        var gustavoSeen: [[AgentSession]] = []
        var allanSeen: [[AgentSession]] = []
        let a = gustavo.sessionsPublisher.sink { gustavoSeen.append($0) }
        let b = allan.sessionsPublisher.sink { allanSeen.append($0) }
        defer { a.cancel(); b.cancel() }
        base.sessions = [busy]
        XCTAssertEqual(gustavoSeen.last, [busy])
        XCTAssertEqual(allanSeen.last, [])
    }

    func testAliasMissingFromTheStatusGetsNoSessions() async throws {
        let client = makeClient(Runner())
        _ = try await client.status()
        let base = BaseMonitor()
        base.sessions = [busy]
        let ghost = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Fantasma", client: client)
        XCTAssertEqual(ghost.sessions, [])
    }

    func testOtherFamilyActiveAccountDoesNotLeakAcrossFamilies() async throws {
        let client = makeClient(Runner())
        _ = try await client.status()   // OpenCode ativa: Personal
        let base = BaseMonitor()
        base.sessions = [busy]
        let personal = CcauthActiveAccountMonitor(base: base, family: .opencode, alias: "Personal", client: client)
        let defaultAccount = CcauthActiveAccountMonitor(base: base, family: .opencode, alias: "Default", client: client)
        XCTAssertEqual(personal.sessions, [busy])
        XCTAssertEqual(defaultAccount.sessions, [])
    }

    func testStartAndStopAcquireAndReleaseTheSharedBaseLease() {
        let base = BaseMonitor()
        let client = makeClient(Runner())
        let lease = CcauthBaseLease(base: base)
        let first = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Gustavo", client: client, lease: lease)
        let second = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Allan", client: client, lease: lease)
        first.start()
        second.start()
        XCTAssertEqual(base.starts, 1, "o base é iniciado uma vez, pelo primeiro anel")
        first.stop()
        XCTAssertEqual(base.stops, 0, "ainda há um anel usando o base")
        second.stop()
        XCTAssertEqual(base.stops, 1)
        second.stop()
        XCTAssertEqual(base.stops, 1, "stop repetido não desfaz o que não foi pego")
    }

    func testStartWithoutALeaseTouchesNothing() {
        let base = BaseMonitor()
        let monitor = CcauthActiveAccountMonitor(base: base, family: .claude, alias: "Gustavo",
                                                 client: makeClient(Runner()))
        monitor.start()
        monitor.stop()
        XCTAssertEqual(base.starts, 0)
        XCTAssertEqual(base.stops, 0)
    }
}

