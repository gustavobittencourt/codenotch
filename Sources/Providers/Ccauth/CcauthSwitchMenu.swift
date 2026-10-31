
import AppKit
import Foundation

/// "Alternar <família> para <alias>…" no menu do notch: os itens, o texto do
/// alerta de confirmação e a ação que roda `ccauth <família> switch <alias>`.
enum CcauthSwitchMenu {
    struct Item: Equatable {
        let family: CcauthFamily
        let alias: String

        var title: String { "Alternar \(CcauthSwitchMenu.familyName(family)) para \(alias)…" }
    }

    struct Alert: Equatable {
        let title: String
        let message: String
        let primary: String
        let cancel: String
    }

    // Textos de `switch-text.ts` (fork Raycast do agent-usage).
    private static let sessionsNote = "Sessões do Claude Code já abertas continuam na conta anterior até serem reiniciadas."
    private static let openCodeNote = "As próximas chamadas do OpenCode Go passam a ser cobradas nesta conta."

    /// Famílias com troca em andamento e o alias de destino (o item desabilitado do
    /// menu diz para qual conta). Só a thread principal mexe.
    @MainActor static var inProgress: [CcauthFamily: String] = [:]

    static func familyName(_ family: CcauthFamily) -> String {
        family == .claude ? "Claude" : "OpenCode Go"
    }

    /// Uma entrada por conta que não é a ativa, Claude antes de OpenCode. Chave
    /// OpenCode rejeitada não entra: trocar para ela falharia.
    static func items(for status: CcauthStatus?) -> [Item] {
        guard let status else { return [] }
        let claudeActive = status.activeAlias(family: .claude)
        let opencodeActive = status.activeAlias(family: .opencode)
        let claude = (status.claude?.accounts ?? [])
            .filter { $0.alias != claudeActive }
            .map { Item(family: .claude, alias: $0.alias) }
        let opencode = (status.opencode?.accounts ?? [])
            .filter { $0.alias != opencodeActive && $0.keyInvalid != true }
            .map { Item(family: .opencode, alias: $0.alias) }
        return claude + opencode
    }

    static func confirmation(family: CcauthFamily, current: String?, target: String) -> Alert {
        let lead = current.map { "Ativa agora: \($0)." } ?? "Nenhuma conta ativa registrada."
        let note = family == .opencode ? openCodeNote : sessionsNote
        return Alert(title: "Alternar \(familyName(family)) para \(target)?",
                     message: "\(lead) \(note)", primary: "Alternar", cancel: "Cancelar")
    }

    static func failure(target: String, message: String) -> Alert {
        Alert(title: "Não foi possível alternar para \(target)", message: message, primary: "OK", cancel: "")
    }

    /// Confirma, troca e relê. A leitura vem depois mesmo na falha: o ccauth pode
    /// ter mexido no estado antes de falhar.
    @MainActor
    static func perform(_ item: Item, client: CcauthClient,
                        confirm: (Alert) -> Bool,
                        showFailure: (Alert) -> Void,
                        refresh: @MainActor () -> Void) async {
        // Uma troca por família: a segunda mexeria no mesmo estado do ccauth e
        // abriria outro alerta. A marca vale já na confirmação e cai em qualquer saída.
        guard inProgress[item.family] == nil else { return }
        let current = client.lastStatus?.activeAlias(family: item.family)
        guard current != item.alias else { return }
        inProgress[item.family] = item.alias
        defer { inProgress[item.family] = nil }
        guard confirm(confirmation(family: item.family, current: current, target: item.alias)) else { return }
        let result = await client.switchAccount(family: item.family, alias: item.alias)
        if case .failure(let error) = result {
            showFailure(failure(target: item.alias, message: error.localizedDescription))
        }
        refresh()
    }

    /// Os itens que o menu mostra agora, lidos do último status (sem status, nenhum).
    /// `refresh` é o mesmo "Refresh now" do notch.
    @MainActor
    static func menuEntries(client: CcauthClient = .shared,
                            refresh: @escaping @MainActor () -> Void) -> [(title: String, action: () -> Void, isEnabled: Bool)] {
        let pending = items(for: client.lastStatus)
        var entries: [(title: String, action: () -> Void, isEnabled: Bool)] = []
        for family in [CcauthFamily.claude, .opencode] {
            if let target = inProgress[family] {
                entries.append((title: "Alternando \(familyName(family)) para \(target)…", action: {}, isEnabled: false))
                continue
            }
            for item in pending where item.family == family {
                let action: () -> Void = {
                    Task { @MainActor in
                        await run(item, client: client, refresh: refresh)
                    }
                }
                entries.append((title: item.title, action: action, isEnabled: true))
            }
        }
        return entries
    }

    @MainActor
    private static func run(_ item: Item, client: CcauthClient, refresh: @MainActor () -> Void) async {
        await perform(item, client: client, confirm: runConfirmation,
                      showFailure: runFailure, refresh: refresh)
    }

    @MainActor
    private static func runConfirmation(_ alert: Alert) -> Bool {
        let panel = NSAlert()
        panel.messageText = alert.title
        panel.informativeText = alert.message
        panel.addButton(withTitle: alert.primary)   // botão padrão
        panel.addButton(withTitle: alert.cancel)
        return panel.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func runFailure(_ alert: Alert) {
        let panel = NSAlert()
        panel.alertStyle = .warning
        panel.messageText = alert.title
        panel.informativeText = alert.message
        panel.addButton(withTitle: alert.primary)
        panel.runModal()
    }
}

        // O app é de barra de menu: sem ativar, o alerta abre atrás das janelas ou sem foco.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.activate(ignoringOtherApps: true)
