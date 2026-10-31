
import XCTest
@testable import Codenotch

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var reply: (stdout: Data, exit: Int32) = (Data(#"{"ok":true}"#.utf8), 0)
    var calls: [[String]] { lock.withLock { recorded } }
    var runner: CcauthClient.Runner {
        { [self] args, _ in
            lock.withLock { recorded.append(args) }
            return reply
        }
    }
}

@MainActor
final class CcauthSwitchMenuTests: XCTestCase {
    // MARK: - Itens

    func testClaudeInactiveAccountGetsAnItemAndTheActiveOneDoesNot() throws {
        let items = CcauthSwitchMenu.items(for: try CcauthFixture.status())
        let claude = items.filter { $0.family == .claude }
        XCTAssertEqual(claude.map(\.alias), ["Allan"])
        XCTAssertEqual(claude.map(\.title), ["Alternar Claude para Allan…"])
    }

    func testOpenCodeSkipsTheActiveAccountAndTheInvalidKey() throws {
        let items = CcauthSwitchMenu.items(for: try CcauthFixture.status())
        let opencode = items.filter { $0.family == .opencode }
        XCTAssertEqual(opencode.map(\.alias), ["Default"], "Personal é a ativa; \"API key\" tem key_invalid")
        XCTAssertEqual(opencode.map(\.title), ["Alternar OpenCode Go para Default…"])
    }

    func testClaudeItemsComeBeforeOpenCodeItems() throws {
        let items = CcauthSwitchMenu.items(for: try CcauthFixture.status())
        XCTAssertEqual(items.map(\.alias), ["Allan", "Default"])
    }

    func testNoStatusMeansNoItems() {
        XCTAssertEqual(CcauthSwitchMenu.items(for: nil), [])
    }

    func testItemsFollowTheActiveAccountAfterASwitch() throws {
        let status = try CcauthStatus.decode(CcauthFixture.statusData(activeClaude: "Allan", activeOpenCode: "Default"))
        let items = CcauthSwitchMenu.items(for: status)
        XCTAssertEqual(items.map(\.alias), ["Gustavo", "Personal"])
    }

    func testActiveAliasComesFromTheFamilyOrFromTheAccountFlag() throws {
        let status = try CcauthFixture.status()
        XCTAssertEqual(status.activeAlias(family: .claude), "Gustavo")
        XCTAssertEqual(status.activeAlias(family: .opencode), "Personal")
        let onlyFlag = try CcauthStatus.decode(Data(
            #"{"schema":2,"claude":{"accounts":[{"alias":"A","active":false},{"alias":"B","active":true}]}}"#.utf8))
        XCTAssertEqual(onlyFlag.activeAlias(family: .claude), "B")
        XCTAssertNil(onlyFlag.activeAlias(family: .opencode))
    }

    func testMenuEntriesAreBuiltFromTheClientLastStatus() async throws {
        let recorder = Recorder()
        recorder.reply = (CcauthFixture.statusData, 0)
        let client = CcauthClient(runner: recorder.runner)
        XCTAssertEqual(CcauthSwitchMenu.menuEntries(client: client, refresh: {}).count, 0, "sem status, sem itens")
        _ = try await client.status()
        let entries = CcauthSwitchMenu.menuEntries(client: client, refresh: {})
        XCTAssertEqual(entries.map(\.title), ["Alternar Claude para Allan…", "Alternar OpenCode Go para Default…"])
    }

    // MARK: - Texto do alerta

    func testConfirmationNamesTheCurrentAndWarnsAboutRunningClaudeSessions() {
        let alert = CcauthSwitchMenu.confirmation(family: .claude, current: "Gustavo", target: "Allan")
        XCTAssertEqual(alert.title, "Alternar Claude para Allan?")
        XCTAssertEqual(alert.message,
                       "Ativa agora: Gustavo. Sessões do Claude Code já abertas continuam na conta anterior até serem reiniciadas.")
        XCTAssertEqual(alert.primary, "Alternar")
        XCTAssertEqual(alert.cancel, "Cancelar")
    }

    func testConfirmationForOpenCodeUsesTheBillingNote() {
        let alert = CcauthSwitchMenu.confirmation(family: .opencode, current: "Personal", target: "Default")
        XCTAssertEqual(alert.title, "Alternar OpenCode Go para Default?")
        XCTAssertEqual(alert.message,
                       "Ativa agora: Personal. As próximas chamadas do OpenCode Go passam a ser cobradas nesta conta.")
    }

    func testConfirmationWithoutAnActiveAccount() {
        let alert = CcauthSwitchMenu.confirmation(family: .claude, current: nil, target: "Allan")
        XCTAssertTrue(alert.message.hasPrefix("Nenhuma conta ativa registrada. "))
    }

    func testFailureAlertCarriesTheCcauthError() {
        let alert = CcauthSwitchMenu.failure(target: "Allan", message: "lock ocupado")
        XCTAssertEqual(alert.title, "Não foi possível alternar para Allan")
        XCTAssertEqual(alert.message, "lock ocupado")
    }

    // MARK: - A ação

    private func item(_ family: CcauthFamily, _ alias: String) -> CcauthSwitchMenu.Item {
        CcauthSwitchMenu.items(for: try! CcauthFixture.status()).first { $0.family == family && $0.alias == alias }!
    }

    func testCancelledConfirmationRunsNothing() async throws {
        let recorder = Recorder()
        recorder.reply = (CcauthFixture.statusData, 0)
        let client = CcauthClient(runner: recorder.runner)
        _ = try await client.status()
        let before = recorder.calls.count
        var refreshed = 0
        var failures: [String] = []
        var asked: [CcauthSwitchMenu.Alert] = []
        await CcauthSwitchMenu.perform(
            item(.claude, "Allan"), client: client,
            confirm: { asked.append($0); return false },
            showFailure: { failures.append($0.message) },
            refresh: { refreshed += 1 })
        XCTAssertEqual(asked.map(\.title), ["Alternar Claude para Allan?"])
        XCTAssertEqual(asked.first?.message.hasPrefix("Ativa agora: Gustavo."), true)
        XCTAssertEqual(recorder.calls.count, before)
        XCTAssertEqual(refreshed, 0)
        XCTAssertEqual(failures, [])
    }

    func testConfirmedSwitchRunsTheCommandInvalidatesAndRefreshes() async throws {
        let recorder = Recorder()
        recorder.reply = (CcauthFixture.statusData, 0)
        let client = CcauthClient(runner: recorder.runner)
        _ = try await client.status()
        recorder.reply = (Data(#"{"ok":true}"#.utf8), 0)
        var refreshed = 0
        var failures: [String] = []
        await CcauthSwitchMenu.perform(
            item(.opencode, "Default"), client: client,
            confirm: { _ in true },
            showFailure: { failures.append($0.message) },
            refresh: { refreshed += 1 })
        XCTAssertEqual(recorder.calls.last, ["opencode", "switch", "Default", "--json", "--lock-wait", "30"])
        XCTAssertEqual(refreshed, 1)
        XCTAssertEqual(failures, [])
        // O cache foi invalidado: a próxima leitura roda o ccauth de novo.
        recorder.reply = (CcauthFixture.statusData, 0)
        let callsBefore = recorder.calls.count
        _ = try await client.status()
        XCTAssertEqual(recorder.calls.count, callsBefore + 1)
    }

    func testFailedSwitchShowsTheErrorAndStillRefreshes() async throws {
        let recorder = Recorder()
        recorder.reply = (CcauthFixture.statusData, 0)
        let client = CcauthClient(runner: recorder.runner)
        _ = try await client.status()
        recorder.reply = (Data(#"{"ok":false,"error":"login expirou"}"#.utf8), 1)
        var refreshed = 0
        var failures: [CcauthSwitchMenu.Alert] = []
        await CcauthSwitchMenu.perform(
            item(.claude, "Allan"), client: client,
            confirm: { _ in true },
            showFailure: { failures.append($0) },
            refresh: { refreshed += 1 })
        XCTAssertEqual(failures.map(\.message), ["login expirou"])
        XCTAssertEqual(failures.first?.title, "Não foi possível alternar para Allan")
        XCTAssertEqual(refreshed, 1, "a falha pode ter mexido no estado: lê de novo")
    }
}

final class CcauthDiscoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "CcauthDiscoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func client(replying json: String?) -> CcauthClient {
        CcauthClient(runner: { _, _ in
            guard let json else { throw CcauthError.notInstalled }
            return (Data(json.utf8), 0)
        })
    }

    private let claudeBusy = #"{"ok":false,"busy":true,"error":"ocupado"}"#
    private func claudeOK(_ aliases: String...) -> String {
        let accounts = aliases.map { #"{"alias":"\#($0)","email":"\#($0.lowercased())@example.com"}"# }.joined(separator: ",")
        return #"{"ok":true,"active":"\#(aliases[0])","accounts":[\#(accounts)]}"#
    }
    private func opencodeOK(_ accounts: String) -> String {
        #"{"ok":true,"available":true,"accounts":[\#(accounts)]}"#
    }
    private func status(claude: String, opencode: String) -> String {
        #"{"schema":2,"ok":true,"claude":\#(claude),"opencode":\#(opencode)}"#
    }

    func testSuccessfulDiscoveryBuildsRingsAndRemembersTheAccounts() {
        let json = status(claude: claudeOK("Allan", "Gustavo"),
                          opencode: opencodeOK(#"{"alias":"Default"},{"alias":"API key","key_invalid":true}"#))
        let providers = CcauthRings.discover(client: client(replying: json), defaults: defaults)
        XCTAssertEqual(providers.map(\.id), ["ccauth-claude-allan", "ccauth-claude-gustavo", "ccauth-opencode-default"])
        // A chave inválida não ganha anel, mas fica na lista lembrada com o aviso.
        XCTAssertEqual(CcauthRings.rememberedAccounts(defaults: defaults).map(\.alias), ["Allan", "Gustavo", "Default", "API key"])
        XCTAssertEqual(CcauthRings.rememberedAccounts(defaults: defaults).last?.keyInvalid, true)
        XCTAssertEqual(CcauthRings.rememberedAccounts(defaults: defaults).first?.email, "allan@example.com")
    }

    func testFamilyThatFailedFallsBackToItsRememberedAccounts() {
        let good = status(claude: claudeOK("Allan", "Gustavo"), opencode: opencodeOK(#"{"alias":"Default"}"#))
        _ = CcauthRings.discover(client: client(replying: good), defaults: defaults)

        let busy = status(claude: claudeBusy, opencode: opencodeOK(#"{"alias":"Default"},{"alias":"Personal"}"#))
        let providers = CcauthRings.discover(client: client(replying: busy), defaults: defaults)
        XCTAssertEqual(providers.map(\.id), [
            "ccauth-claude-allan", "ccauth-claude-gustavo", "ccauth-opencode-default", "ccauth-opencode-personal"],
            "Claude vem da lista lembrada; OpenCode, da leitura nova")
        XCTAssertEqual(providers.first?.email, "allan@example.com")
        // A lista lembrada da família que falhou não é apagada.
        XCTAssertEqual(CcauthRings.rememberedAccounts(defaults: defaults).filter { $0.family == .claude }.count, 2)
    }

    func testFailedDiscoveryUsesTheRememberedAccountsOfBothFamilies() {
        let good = status(claude: claudeOK("Allan"), opencode: opencodeOK(#"{"alias":"Default"}"#))
        _ = CcauthRings.discover(client: client(replying: good), defaults: defaults)
        let providers = CcauthRings.discover(client: client(replying: nil), defaults: defaults)
        XCTAssertEqual(providers.map(\.id), ["ccauth-claude-allan", "ccauth-opencode-default"])
    }

    func testWithNothingRememberedAFailedDiscoveryLeavesTheNativeRings() {
        let providers = CcauthRings.discover(client: client(replying: nil), defaults: defaults)
        XCTAssertTrue(providers.isEmpty)
        XCTAssertFalse(CcauthRings.replacesNativeClaude(providers))
        XCTAssertFalse(CcauthRings.replacesNativeOpenCode(providers))
    }

    func testAnHealthyFamilyWithoutAccountsForgetsTheOldOnes() {
        let good = status(claude: claudeOK("Allan"), opencode: opencodeOK(#"{"alias":"Default"}"#))
        _ = CcauthRings.discover(client: client(replying: good), defaults: defaults)
        let emptied = status(claude: claudeOK("Allan"), opencode: opencodeOK(""))
        let providers = CcauthRings.discover(client: client(replying: emptied), defaults: defaults)
        XCTAssertEqual(providers.map(\.id), ["ccauth-claude-allan"], "ok:true é a palavra do ccauth: a conta saiu")
    }

    func testUnreadableRememberedDataIsTreatedAsNothingRemembered() {
        defaults.set(Data("lixo".utf8), forKey: CcauthRings.rememberedAccountsKey)
        XCTAssertEqual(CcauthRings.rememberedAccounts(defaults: defaults), [])
        XCTAssertTrue(CcauthRings.discover(client: client(replying: nil), defaults: defaults).isEmpty)
    }
}

final class CcauthRingsTests: XCTestCase {
    func testProvidersFollowTheStatusAndSkipTheInvalidKey() throws {
        let providers = CcauthRings.providers(from: try CcauthFixture.status())
        XCTAssertEqual(providers.map(\.id), [
            "ccauth-claude-allan", "ccauth-claude-gustavo",
            "ccauth-opencode-personal", "ccauth-opencode-default",
        ])
        XCTAssertEqual(providers.map(\.displayName), ["Allan", "Gustavo", "Personal", "Default"])
        XCTAssertEqual(providers.first?.email, "allan@example.com")
    }

    func testFamiliesWithoutAccountsReplaceNothing() throws {
        let onlyClaude = try CcauthStatus.decode(Data(
            #"{"schema":2,"claude":{"accounts":[{"alias":"A","active":true}]},"opencode":{"available":false,"accounts":[]}}"#.utf8))
        let providers = CcauthRings.providers(from: onlyClaude)
        XCTAssertTrue(CcauthRings.replacesNativeClaude(providers))
        XCTAssertFalse(CcauthRings.replacesNativeOpenCode(providers))
        XCTAssertFalse(CcauthRings.replacesNativeClaude([]))
    }

    func testOpenCodeWithOnlyAnInvalidKeyKeepsTheNativeProvider() throws {
        let status = try CcauthStatus.decode(Data(
            #"{"schema":2,"opencode":{"available":true,"accounts":[{"alias":"K","kind":"key","key_invalid":true}]}}"#.utf8))
        let providers = CcauthRings.providers(from: status)
        XCTAssertTrue(providers.isEmpty)
        XCTAssertFalse(CcauthRings.replacesNativeOpenCode(providers))
    }

    func testRingIDsStartConnectedLikeTheNativeClaudeOnes() {
        XCTAssertTrue(CcauthRings.isCcauth(providerID: "ccauth-claude-allan"))
        XCTAssertTrue(CcauthRings.isCcauth(providerID: "ccauth-opencode-default"))
        XCTAssertFalse(CcauthRings.isCcauth(providerID: "claude"))
        XCTAssertFalse(CcauthRings.isCcauth(providerID: "opencode"))
        XCTAssertTrue(Preferences.isDefaultOnFamily("ccauth-claude-allan"))
        XCTAssertTrue(Preferences.isDefaultOnFamily("ccauth-opencode-default"))
        XCTAssertFalse(Preferences.isDefaultOnFamily("opencode"), "o nativo continua começando desligado")
    }
}



@MainActor
final class CcauthContextMenuTests: XCTestCase {
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    func testDynamicItemsComeRightAfterRefreshNowAndRunTheirAction() throws {
        let controller = NotchWindowController()
        var ran: [String] = []
        controller.dynamicMenuItems = { [
            (title: "Alternar Claude para Allan…", action: { ran.append("Allan") }),
            (title: "Alternar OpenCode Go para Default…", action: { ran.append("Default") }),
        ] }
        let menu = controller.contextMenuForTesting()
        let list = titles(menu)
        let refresh = try XCTUnwrap(list.firstIndex(of: L10n.t("Refresh now")))
        XCTAssertEqual(Array(list[(refresh + 1)...].prefix(2)),
                       ["Alternar Claude para Allan…", "Alternar OpenCode Go para Default…"])
        XCTAssertTrue(list.contains(L10n.t("Settings…")), "os itens existentes continuam")

        let item = try XCTUnwrap(menu.items.first { $0.title == "Alternar OpenCode Go para Default…" })
        let target = try XCTUnwrap(item.target as? NSObject)
        _ = target.perform(try XCTUnwrap(item.action), with: item)
        XCTAssertEqual(ran, ["Default"])
    }

    func testMenuHasNoExtraItemsByDefault() {
        let controller = NotchWindowController()
        XCTAssertFalse(titles(controller.contextMenuForTesting()).contains { $0.hasPrefix("Alternar") })
    }

    func testTheFleetHandsItsDynamicItemsToEveryControllerAtOpenTime() throws {
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        var entries = [(title: String, action: () -> Void)]()
        fleet.dynamicMenuItems = { entries }
        fleet.reconcileForTesting()
        defer { fleet.stop() }
        let controller = try XCTUnwrap(fleet.controllersForTesting.first)
        XCTAssertFalse(titles(controller.contextMenuForTesting()).contains { $0.hasPrefix("Alternar") })
        // Avaliado a cada abertura: o que muda depois entra no menu seguinte.
        entries = [(title: "Alternar Claude para Allan…", action: {})]
        XCTAssertTrue(titles(controller.contextMenuForTesting()).contains("Alternar Claude para Allan…"))
    }
}

