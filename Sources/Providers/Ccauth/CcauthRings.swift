
import Foundation

/// Que anéis o ccauth cria e o que eles substituem dos providers nativos.
enum CcauthRings {
    /// Um provider por conta. OpenCode com `key_invalid` não ganha anel: a chave
    /// foi rejeitada e não há cota a mostrar.
    static func providers(from status: CcauthStatus, client: CcauthClient = .shared) -> [CcauthAccountProvider] {
        let claude = (status.claude?.accounts ?? []).map {
            CcauthAccountProvider(family: .claude, alias: $0.alias, email: $0.email, client: client)
        }
        let opencode = (status.opencode?.accounts ?? []).filter { $0.keyInvalid != true }.map {
            CcauthAccountProvider(family: .opencode, alias: $0.alias, email: $0.email, client: client)
        }
        return claude + opencode
    }

    /// Com anel de conta Claude do ccauth, o anel nativo do Claude sai (seria a
    /// mesma conta contada duas vezes).
    static func replacesNativeClaude(_ providers: [CcauthAccountProvider]) -> Bool {
        providers.contains { $0.family == .claude }
    }

    static func replacesNativeOpenCode(_ providers: [CcauthAccountProvider]) -> Bool {
        providers.contains { $0.family == .opencode }
    }

    /// Os ids dos anéis do ccauth (ver `CcauthAccountProvider.providerID`).
    static func isCcauth(providerID: String) -> Bool {
        providerID.hasPrefix("ccauth-claude-") || providerID.hasPrefix("ccauth-opencode-")
    }
}

