
import Combine
import XCTest
@testable import Codenotch

/// Runner falso: grava as chamadas e devolve a saída combinada.
private final class FakeRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(args: [String], timeout: TimeInterval)] = []
    var delay: TimeInterval = 0
    var reply: (stdout: Data, exit: Int32) = (CcauthFixture.statusData, 0)
    var failure: Error?

    var calls: [[String]] { lock.withLock { recorded.map(\.args) } }
    var timeouts: [TimeInterval] { lock.withLock { recorded.map(\.timeout) } }

    var runner: CcauthClient.Runner {
        { [self] args, timeout in
            lock.withLock { recorded.append((args, timeout)) }
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if let failure { throw failure }
            return reply
        }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current.addTimeInterval(seconds) } }
}

final class CcauthClientTests: XCTestCase {
    private func make(_ fake: FakeRunner, clock: Clock = Clock()) -> CcauthClient {
        CcauthClient(runner: fake.runner, now: { clock.now })
    }

    // MARK: - status()

    func testStatusRunsTheJSONCommandWithLockWaitAndMaxAge() async throws {
        let fake = FakeRunner()
        let status = try await make(fake).status()
        XCTAssertEqual(status.schema, 2)
        XCTAssertEqual(fake.calls, [["status", "--json", "--max-age", "60", "--lock-wait", "30"]])
    }

    func testConcurrentStatusCallsShareOneRun() async throws {
        let fake = FakeRunner()
        fake.delay = 0.2
        let client = make(fake)
        async let first = client.status()
        async let second = client.status()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testStatusIsReusedForTwentySecondsThenRefetched() async throws {
        let fake = FakeRunner()
        let clock = Clock()
        let client = make(fake, clock: clock)
        _ = try await client.status()
        clock.advance(19)
        _ = try await client.status()
        XCTAssertEqual(fake.calls.count, 1)
        clock.advance(2)
        _ = try await client.status()
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testInvalidateDropsTheCache() async throws {
        let fake = FakeRunner()
        let client = make(fake)
        _ = try await client.status()
        client.invalidate()
        _ = try await client.status()
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testInvalidateDuringARunKeepsItsResultOutOfTheCache() async throws {
        let fake = FakeRunner()
        fake.delay = 0.2
        let client = make(fake)
        async let running = client.status()
        try await Task.sleep(nanoseconds: 50_000_000)
        client.invalidate()
        _ = try await running
        _ = try await client.status()
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testFailedRunIsNotCached() async throws {
        let fake = FakeRunner()
        fake.failure = CcauthError.notInstalled
        let client = make(fake)
        do {
            _ = try await client.status()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CcauthError, .notInstalled)
        }
        fake.failure = nil
        _ = try await client.status()
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testLastStatusIsNilUntilAReadSucceeds() async throws {
        let client = make(FakeRunner())
        XCTAssertNil(client.lastStatus)
        _ = try await client.status()
        XCTAssertEqual(client.lastStatus?.claude?.active, "Gustavo")
    }

    // MARK: - statusPublisher

    func testStatusPublisherEmitsWhenTheStatusChangesAndNotForTheSameStatus() async throws {
        let fake = FakeRunner()
        let client = make(fake)
        var received: [CcauthStatus] = []
        let subscription = client.statusPublisher.sink { received.append($0) }
        defer { subscription.cancel() }

        _ = try await client.status()
        XCTAssertEqual(received.count, 1)

        client.invalidate()
        _ = try await client.status()   // mesma saída: não é mudança
        XCTAssertEqual(received.count, 1)

        fake.reply = (try CcauthFixture.statusData(activeClaude: "Allan"), 0)
        client.invalidate()
        _ = try await client.status()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last?.claude?.active, "Allan")
        XCTAssertEqual(received.last?.claude?.accounts?.first { $0.alias == "Allan" }?.active, true)
    }

    func testStatusPublisherReplaysTheLatestStatusToALateSubscriber() async throws {
        let client = make(FakeRunner())
        _ = try await client.status()
        var received: [CcauthStatus] = []
        let subscription = client.statusPublisher.sink { received.append($0) }
        defer { subscription.cancel() }
        XCTAssertEqual(received.count, 1)
    }

    func testStatusPublisherIsSilentBeforeAnyRead() {
        let client = make(FakeRunner())
        var received = 0
        let subscription = client.statusPublisher.sink { _ in received += 1 }
        defer { subscription.cancel() }
        XCTAssertEqual(received, 0)
    }

    func testStatusPublisherCarriesTheDiscoveredStatus() {
        let client = make(FakeRunner())
        var received: [CcauthStatus] = []
        let subscription = client.statusPublisher.sink { received.append($0) }
        defer { subscription.cancel() }
        XCTAssertNotNil(client.discoverAccountsSync())
        XCTAssertEqual(received.count, 1)
    }

    func testSchema3IsRejected() async throws {
        let fake = FakeRunner()
        fake.reply = (Data(#"{"schema":3,"ok":true}"#.utf8), 0)
        let client = make(fake)
        do {
            _ = try await client.status()
            XCTFail("expected unsupportedSchema")
        } catch {
            XCTAssertEqual(error as? CcauthError, .unsupportedSchema(3))
        }
        XCTAssertNil(client.lastStatus)
    }

    func testStatusReportsTheErrorOfAnOkFalseAnswer() async throws {
        let fake = FakeRunner()
        fake.reply = (Data(#"{"ok":false,"error":"lock ocupado"}"#.utf8), 75)
        do {
            _ = try await make(fake).status()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CcauthError, .failed("lock ocupado"))
        }
    }

    func testStatusWithGarbageOutputFailsWithItsLastLine() async throws {
        let fake = FakeRunner()
        fake.reply = (Data("aviso\nccauth quebrou\n".utf8), 1)
        do {
            _ = try await make(fake).status()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CcauthError, .failed("ccauth quebrou"))
        }
    }

    // MARK: - discoverAccountsSync()

    func testDiscoverRunsWithoutUsageAndReturnsTheAccounts() {
        let fake = FakeRunner()
        let status = make(fake).discoverAccountsSync()
        XCTAssertEqual(status?.claude?.accounts?.count, 2)
        XCTAssertEqual(fake.calls, [["status", "--json", "--no-usage", "--lock-wait", "10"]])
    }

    func testDiscoverReturnsNilWhenTheRunnerFailsOrTheSchemaIsOther() {
        let broken = FakeRunner()
        broken.failure = CcauthError.notInstalled
        XCTAssertNil(make(broken).discoverAccountsSync())

        let other = FakeRunner()
        other.reply = (Data(#"{"schema":3,"ok":true}"#.utf8), 0)
        XCTAssertNil(make(other).discoverAccountsSync())
    }

    func testDiscoverFeedsLastStatusButNotTheUsageCache() async throws {
        let fake = FakeRunner()
        let client = make(fake)
        XCTAssertNotNil(client.discoverAccountsSync())
        XCTAssertNotNil(client.lastStatus)
        _ = try await client.status()
        XCTAssertEqual(fake.calls.count, 2, "a quota-less discovery must not answer status()")
    }

    // MARK: - switchAccount

    private func failure(_ result: Result<Void, CcauthError>) -> CcauthError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    func testSwitchRunsTheFamilyCommandWithTwoMinuteTimeout() async {
        let fake = FakeRunner()
        fake.reply = (Data(#"{"ok":true}"#.utf8), 0)
        let result = await make(fake).switchAccount(family: .opencode, alias: "Default")
        XCTAssertNil(failure(result))
        XCTAssertEqual(fake.calls, [["opencode", "switch", "Default", "--json", "--lock-wait", "30"]])
        XCTAssertEqual(fake.timeouts, [120])
    }

    func testSwitchWithOkFalseReturnsTheErrorText() async {
        let fake = FakeRunner()
        fake.reply = (Data(#"{"ok":false,"error":"login expirado — ccauth claude login"}"#.utf8), 1)
        let result = await make(fake).switchAccount(family: .claude, alias: "Allan")
        XCTAssertEqual(failure(result), .failed("login expirado — ccauth claude login"))
    }

    func testSwitchWhenRunnerThrowsReturnsThatError() async {
        let fake = FakeRunner()
        fake.failure = CcauthError.timedOut
        let result = await make(fake).switchAccount(family: .claude, alias: "Allan")
        XCTAssertEqual(failure(result), .timedOut)
    }

    func testSwitchInvalidatesTheStatusCache() async throws {
        let fake = FakeRunner()
        let client = make(fake)
        _ = try await client.status()
        fake.reply = (Data(#"{"ok":true}"#.utf8), 0)
        _ = await client.switchAccount(family: .claude, alias: "Allan")
        fake.reply = (CcauthFixture.statusData, 0)
        _ = try await client.status()
        XCTAssertEqual(fake.calls.filter { $0.first == "status" }.count, 2)
    }

    func testSwitchInvalidatesEvenWhenItFails() async throws {
        let fake = FakeRunner()
        let client = make(fake)
        _ = try await client.status()
        fake.reply = (Data(#"{"ok":false,"error":"x"}"#.utf8), 1)
        _ = await client.switchAccount(family: .claude, alias: "Allan")
        fake.reply = (CcauthFixture.statusData, 0)
        _ = try await client.status()
        XCTAssertEqual(fake.calls.filter { $0.first == "status" }.count, 2)
    }

    // MARK: - Real process plumbing (no ccauth needed)

    func testEnvironmentCarriesPathHomeUserAndLogname() {
        let env = CcauthClient.environment(from: ["HOME": "/Users/x", "USER": "x", "LOGNAME": "x", "SECRET": "no"])
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertEqual(env["USER"], "x")
        XCTAssertEqual(env["LOGNAME"], "x")
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/Users/x/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(env["SECRET"])
    }

    func testLocateBinaryTakesTheFirstDirectoryHoldingAnExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccauth-bin-\(UUID())")
        let first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b")
        for dir in [first, second] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let name = "ccauth"
        // Em `a` há um arquivo não executável: tem de ser ignorado.
        try Data().write(to: first.appendingPathComponent(name))
        try Data("#!/bin/sh\n".utf8).write(to: second.appendingPathComponent(name))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.appendingPathComponent(name).path)
        XCTAssertEqual(CcauthClient.locateBinary(in: [first.path, second.path])?.path, second.appendingPathComponent(name).path)
        XCTAssertNil(CcauthClient.locateBinary(in: [first.path]))
    }

    func testRunProcessCapturesStdoutAndExitCode() async throws {
        let out = try await CcauthClient.runProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                                    arguments: ["-c", "printf hi; exit 3"],
                                                    environment: [:], timeout: 10)
        XCTAssertEqual(String(data: out.stdout, encoding: .utf8), "hi")
        XCTAssertEqual(out.exit, 3)
    }

    func testRunProcessTerminatesTheChildOnTimeout() async throws {
        let started = Date()
        do {
            _ = try await CcauthClient.runProcess(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                  arguments: ["30"], environment: [:], timeout: 0.3)
            XCTFail("expected timedOut")
        } catch {
            XCTAssertEqual(error as? CcauthError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: - CcauthAccountProvider

    func testProviderReadsItsAccountFromTheSharedStatus() async throws {
        let fake = FakeRunner()
        let provider = CcauthAccountProvider(family: .opencode, alias: "Default",
                                             email: "default@example.com", client: make(fake))
        XCTAssertEqual(provider.id, "ccauth-opencode-default")
        XCTAssertEqual(provider.displayName, "Default")
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.id, "ccauth-opencode-default")
        XCTAssertEqual(snapshot.displayName, "Default")
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertEqual(snapshot.windows.map(\.id), ["rolling", "weekly", "monthly"])
    }

    func testProvidersOfTheSameStatusCostOneRun() async throws {
        let fake = FakeRunner()
        fake.delay = 0.1
        let client = make(fake)
        let providers = [
            CcauthAccountProvider(family: .claude, alias: "Allan", email: nil, client: client),
            CcauthAccountProvider(family: .claude, alias: "Gustavo", email: nil, client: client),
            CcauthAccountProvider(family: .opencode, alias: "Personal", email: nil, client: client),
        ]
        for provider in providers { _ = try await provider.fetchSnapshot() }
        async let a = providers[0].fetchSnapshot()
        async let b = providers[1].fetchSnapshot()
        _ = try await (a, b)
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testProviderOfAVanishedAccountNeedsAuth() async throws {
        let provider = CcauthAccountProvider(family: .claude, alias: "Removida", email: nil, client: make(FakeRunner()))
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch UsageProviderError.needsAuth {
        }
    }

    func testProviderOfAnInvalidKeyNeedsAuth() async throws {
        let provider = CcauthAccountProvider(family: .opencode, alias: "API key", email: nil, client: make(FakeRunner()))
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch UsageProviderError.needsAuth {
        }
    }

    func testProviderAccountAndSignInRoute() async throws {
        let client = make(FakeRunner())
        let active = CcauthAccountProvider(family: .claude, alias: "Gustavo", email: "gustavo@example.com", client: client)
        let inactive = CcauthAccountProvider(family: .opencode, alias: "Default", email: "default@example.com", client: client)
        XCTAssertEqual(active.account()?.plan, nil, "sem status ainda, não se sabe quem está ativa")
        _ = try await client.status()
        XCTAssertEqual(active.account(), ProviderAccount(label: "gustavo@example.com", plan: "Ativa",
                                                         source: "ccauth", manageURL: nil))
        XCTAssertEqual(inactive.account()?.plan, "Go")
        XCTAssertEqual(active.signInRoute, .command("ccauth claude login", name: "ccauth"))
        XCTAssertEqual(inactive.signInRoute, .command("ccauth opencode switch", name: "ccauth"))
        XCTAssertEqual(active.glyph, .claude)
        XCTAssertEqual(inactive.glyph, .opencode)
    }

    // MARK: - Família com ok:false

    /// Claude falhou (ocupado ou erro); OpenCode veio bom.
    private static func claudeFailed(busy: Bool, error: String) -> (stdout: Data, exit: Int32) {
        let json = """
        {"schema":2,"ok":true,
         "claude":{"ok":false,"busy":\(busy),"error":"\(error)"},
         "opencode":{"ok":true,"available":true,"active":"Default","accounts":[
           {"alias":"Default","quota":{"rolling":{"used_percent":10}}}]}}
        """
        return (Data(json.utf8), 0)
    }

    func testProviderOfABusyFamilyTimesOutInsteadOfNeedingAuth() async throws {
        let fake = FakeRunner()
        fake.reply = Self.claudeFailed(busy: true, error: "ocupado")
        let provider = CcauthAccountProvider(family: .claude, alias: "Gustavo", email: nil, client: make(fake))
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected timedOut")
        } catch UsageProviderError.timedOut {
        }
    }

    func testProviderOfAFailedFamilyReportsTheCcauthError() async throws {
        let fake = FakeRunner()
        fake.reply = Self.claudeFailed(busy: false, error: "RuntimeError: quebrou")
        let provider = CcauthAccountProvider(family: .claude, alias: "Gustavo", email: nil, client: make(fake))
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected apiError")
        } catch UsageProviderError.apiError(let message) {
            XCTAssertEqual(message, "RuntimeError: quebrou")
        }
    }

    func testTheOtherFamilyKeepsWorkingWhenOneFamilyFailed() async throws {
        let fake = FakeRunner()
        fake.reply = Self.claudeFailed(busy: true, error: "ocupado")
        let provider = CcauthAccountProvider(family: .opencode, alias: "Default", email: nil, client: make(fake))
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.windows.map(\.id), ["rolling"])
    }

    func testAFailedFamilyDoesNotReplaceTheLastGoodOneInLastStatus() async throws {
        let fake = FakeRunner()
        let client = make(fake)
        _ = try await client.status()
        client.invalidate()
        fake.reply = Self.claudeFailed(busy: true, error: "ocupado")
        let raw = try await client.status()
        XCTAssertEqual(raw.claude?.ok, false, "quem lê o status vê a falha (o anel precisa dela)")
        let last = try XCTUnwrap(client.lastStatus)
        XCTAssertEqual(last.claude?.accounts?.map(\.alias), ["Allan", "Gustavo"], "o menu segue na última família boa")
        XCTAssertEqual(last.activeAlias(family: .claude), "Gustavo")
        XCTAssertEqual(last.opencode?.accounts?.map(\.alias), ["Default"], "a família boa é a nova")
    }

    func testAFamilyThatNeverWorkedStaysFailedInLastStatus() async throws {
        let fake = FakeRunner()
        fake.reply = Self.claudeFailed(busy: false, error: "quebrou")
        let client = make(fake)
        _ = try await client.status()
        XCTAssertEqual(client.lastStatus?.claude?.ok, false)
        XCTAssertNil(client.lastStatus?.activeAlias(family: .claude))
    }

    func testTheStatusPublisherAlsoCarriesTheMergedStatus() async throws {
        let fake = FakeRunner()
        let client = make(fake)
        var received: [CcauthStatus] = []
        let subscription = client.statusPublisher.sink { received.append($0) }
        defer { subscription.cancel() }
        _ = try await client.status()
        client.invalidate()
        fake.reply = Self.claudeFailed(busy: true, error: "ocupado")
        _ = try await client.status()
        XCTAssertEqual(received.last?.claude?.accounts?.map(\.alias), ["Allan", "Gustavo"])
    }
}
