
import Foundation

/// Que anéis o ccauth cria e o que eles substituem dos providers nativos.
/// Uma conta lembrada entre aberturas do app.
struct CcauthKnownAccount: Codable, Equatable {
    let family: CcauthFamily
    let alias: String
    let email: String?
    let keyInvalid: Bool
    /// Opcional: a lista lembrada por versões antigas não tem o campo.
    var loginExpired: Bool? = nil
}

enum CcauthRings {
    static let rememberedAccountsKey = "ccauth.rememberedAccounts"
    private static let families: [CcauthFamily] = [.claude, .opencode]

    /// As contas da última descoberta que deu certo (por família), para o app
    /// ainda montar os anéis quando o ccauth está ocupado ou falha na abertura.
    static func rememberedAccounts(defaults: UserDefaults = .standard) -> [CcauthKnownAccount] {
        guard let data = defaults.data(forKey: rememberedAccountsKey) else { return [] }
        return (try? JSONDecoder().decode([CcauthKnownAccount].self, from: data)) ?? []
    }

    /// Os anéis da abertura do app. Família lida com `ok:true` vale e é lembrada;
    /// família que falhou (ou descoberta que falhou) usa a lista lembrada dela.
    /// Sem nada lembrado, volta vazio e ficam os anéis nativos.
    static func discover(client: CcauthClient = .shared, defaults: UserDefaults = .standard) -> [CcauthAccountProvider] {
        let status = client.discoverAccountsSync()
        let remembered = rememberedAccounts(defaults: defaults)
        var known: [CcauthKnownAccount] = []
        for family in families {
            if let status, let fresh = knownAccounts(of: family, in: status) {
                known += fresh
            } else {
                known += remembered.filter { $0.family == family }
            }
        }
        if status != nil, let data = try? JSONEncoder().encode(known) {
            defaults.set(data, forKey: rememberedAccountsKey)
        }
        return providers(from: known, client: client)
    }

    /// Nil quando o ccauth não leu a família (ausente ou `ok:false`).
    private static func knownAccounts(of family: CcauthFamily, in status: CcauthStatus) -> [CcauthKnownAccount]? {
        guard status.failure(family: family) == nil else { return nil }
        switch family {
        case .claude:
            guard let family = status.claude else { return nil }
            return (family.accounts ?? []).map {
                CcauthKnownAccount(family: .claude, alias: $0.alias, email: $0.email, keyInvalid: false,
                                   loginExpired: $0.loginExpired)
            }
        case .opencode:
            guard let family = status.opencode else { return nil }
            return (family.accounts ?? []).map {
                CcauthKnownAccount(family: .opencode, alias: $0.alias, email: $0.email, keyInvalid: $0.keyInvalid == true,
                                   loginExpired: $0.loginExpired)
            }
        }
    }

    /// Um provider por conta. OpenCode com `key_invalid` não ganha anel: a chave
    /// foi rejeitada e não há cota a mostrar. Login vencido também não.
    static func providers(from status: CcauthStatus, client: CcauthClient = .shared) -> [CcauthAccountProvider] {
        providers(from: families.flatMap { knownAccounts(of: $0, in: status) ?? [] }, client: client)
    }

    static func providers(from accounts: [CcauthKnownAccount], client: CcauthClient = .shared) -> [CcauthAccountProvider] {
        var seen = Set<String>()
        var result: [CcauthAccountProvider] = []
        for account in accounts where !account.keyInvalid && account.loginExpired != true {
            // O id é a identidade do anel no store: alias que vira slug vazio ou
            // repete um id ("Allan"/"allan") não pode virar um segundo anel.
            guard !CcauthAccountProvider.slug(of: account.alias).isEmpty else {
                Log.usage.notice("ccauth: alias sem letra nem dígito ignorado (\(account.family.rawValue, privacy: .public))")
                continue
            }
            let provider = CcauthAccountProvider(family: account.family, alias: account.alias,
                                                 email: account.email, client: client)
            guard seen.insert(provider.id).inserted else {
                Log.usage.notice("ccauth: alias repetido ignorado: \(provider.id, privacy: .public)")
                continue
            }
            result.append(provider)
        }
        return result
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

