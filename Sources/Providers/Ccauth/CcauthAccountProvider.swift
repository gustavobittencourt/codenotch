
import Foundation

/// Um anel por conta do `ccauth`. Todas as contas leem o mesmo status do
/// `CcauthClient`, que coalesce a leitura; o provider só escolhe a sua.
struct CcauthAccountProvider: UsageProvider {
    let family: CcauthFamily
    let alias: String
    let email: String?
    let id: String
    let displayName: String
    let glyph: ProviderGlyph
    private let client: CcauthClient

    init(family: CcauthFamily, alias: String, email: String?, client: CcauthClient = .shared) {
        self.family = family
        self.alias = alias
        self.email = email
        self.client = client
        self.id = Self.providerID(family: family, alias: alias)
        self.displayName = alias
        self.glyph = family == .claude ? .claude : .opencode
    }

    /// Alias em minúsculas; o que não é letra nem dígito vira "-" (sem repetir nem sobrar nas pontas).
    static func slug(of alias: String) -> String {
        var slug = ""
        for character in alias.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty && !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    /// `ccauth-<família>-<slug do alias>`.
    static func providerID(family: CcauthFamily, alias: String) -> String {
        "ccauth-\(family.rawValue)-\(slug(of: alias))"
    }

    var signInRoute: SignInRoute {
        switch family {
        case .claude:   return .command("ccauth claude login", name: "ccauth")
        case .opencode: return .command("ccauth opencode switch", name: "ccauth")
        }
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let status: CcauthStatus
        do {
            status = try await client.status()
        } catch CcauthError.timedOut {
            throw UsageProviderError.timedOut
        } catch {
            throw UsageProviderError.apiError(error.localizedDescription)
        }
        // Família que o ccauth não leu não é conta que sumiu: pedir login de novo
        // seria o conselho errado.
        if let failure = status.failure(family: family) {
            throw failure.busy ? UsageProviderError.timedOut : UsageProviderError.apiError(failure.message)
        }
        switch family {
        case .claude:
            guard let account = status.claude?.accounts?.first(where: { $0.alias == alias }) else {
                throw UsageProviderError.needsAuth
            }
            return try account.snapshot(providerID: id)
        case .opencode:
            guard let account = status.opencode?.accounts?.first(where: { $0.alias == alias }) else {
                throw UsageProviderError.needsAuth
            }
            return try account.snapshot(providerID: id)
        }
    }

    func account() -> ProviderAccount? {
        let status = client.lastStatus
        let plan: String?
        switch family {
        case .claude:
            plan = status?.claude?.accounts?.first(where: { $0.alias == alias })?.plan
        case .opencode:
            plan = status?.opencode?.accounts?.first(where: { $0.alias == alias })?.plan
        }
        return ProviderAccount(label: email, plan: plan, source: "ccauth", manageURL: nil)
    }
}

