
import Foundation

/// As famílias de conta que o `ccauth` gere. O valor cru é o subcomando da CLI.
enum CcauthFamily: String, Equatable {
    case claude
    case opencode
}

/// A saída de `ccauth status --json` (schema 2).
///
/// Tudo é opcional, exceto o alias da conta: `--no-usage` omite a cota inteira
/// e o ccauth pode acrescentar campos ou deixar datas como `null`.
struct CcauthStatus: Decodable, Equatable {
    var schema: Int?
    var ok: Bool?
    var error: String?
    var generatedAt: Date?
    var warnings: [String]?
    var claude: CcauthClaudeFamily?
    var opencode: CcauthOpenCodeFamily?

    /// O decoder que lê o ccauth: chaves em snake_case e datas ISO 8601 com `Z`,
    /// com ou sem fração de segundo.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = plain.date(from: text) ?? fractional.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "data inválida: \(text)"))
            }
            return date
        }
        return decoder
    }

    static func decode(_ data: Data) throws -> CcauthStatus {
        try makeDecoder().decode(CcauthStatus.self, from: data)
    }
}

extension CcauthStatus {
    /// A conta ativa da família: a que o ccauth nomeia no topo da família ou,
    /// sem isso, a que traz `active: true`.
    func activeAlias(family: CcauthFamily) -> String? {
        switch family {
        case .claude:
            return claude?.active ?? claude?.accounts?.first { $0.active == true }?.alias
        case .opencode:
            return opencode?.active ?? opencode?.accounts?.first { $0.active == true }?.alias
        }
    }
}

struct CcauthClaudeFamily: Decodable, Equatable {
    var ok: Bool?
    var active: String?
    var accounts: [CcauthClaudeAccount]?
}

struct CcauthOpenCodeFamily: Decodable, Equatable {
    var ok: Bool?
    var available: Bool?
    var unavailableReason: String?
    var active: String?
    var accounts: [CcauthOpenCodeAccount]?
}

/// Uma janela de cota. `used_percent` vai de 0 a 100.
struct CcauthWindow: Decodable, Equatable {
    var usedPercent: Double?
    var resetsAt: Date?
    var exhausted: Bool?
}

struct CcauthClaudeQuota: Decodable, Equatable {
    var session: CcauthWindow?
    var week: CcauthWindow?
    var fable: CcauthWindow?
    var fetchedAt: Date?
    var stale: Bool?
    var staleReason: String?
}

struct CcauthOpenCodeQuota: Decodable, Equatable {
    var rolling: CcauthWindow?
    var weekly: CcauthWindow?
    var monthly: CcauthWindow?
    var fetchedAt: Date?
    var stale: Bool?
    var staleReason: String?
}

struct CcauthClaudeAccount: Decodable, Equatable {
    let alias: String
    var email: String?
    var active: Bool?
    var inUse: Bool?
    var loginExpiresAt: Date?
    var quota: CcauthClaudeQuota?
}

struct CcauthOpenCodeAccount: Decodable, Equatable {
    let alias: String
    var credentialId: String?
    var kind: String?
    var email: String?
    var workspace: String?
    var active: Bool?
    var loginExpiresAt: Date?
    var keyInvalid: Bool?
    var quota: CcauthOpenCodeQuota?
}

// MARK: - Mapeamento para o modelo do Codenotch

extension CcauthClaudeAccount {
    /// O texto do tooltip. Cor sozinha não diz qual conta está ativa.
    var plan: String? { active == true ? "Ativa" : nil }

    /// Mesmos ids e rótulos do provider nativo (`ClaudeOAuthProvider`), para o
    /// resto do app tratar o anel como qualquer outro anel do Claude.
    var windows: [LimitWindow] {
        guard let quota else { return [] }
        let day: TimeInterval = 86_400
        let candidates: [(id: String, label: String, window: CcauthWindow?, duration: TimeInterval)] = [
            ("session", L10n.t("Current session"), quota.session, 5 * 3600),
            ("weekly_all", L10n.t("All models"), quota.week, 7 * day),
            ("weekly_fable", "Fable", quota.fable, 7 * day),
        ]
        return candidates.compactMap {
            ccauthLimitWindow(id: $0.id, label: $0.label, window: $0.window, duration: $0.duration)
        }
    }

    func snapshot(providerID: String) throws -> ProviderSnapshot {
        let windows = self.windows
        guard !windows.isEmpty else { throw UsageProviderError.badResponse(status: 0) }
        return ProviderSnapshot(
            id: providerID,
            displayName: alias,
            glyph: .claude,
            fidelity: .official,
            status: ccauthStatus(stale: quota?.stale, fetchedAt: quota?.fetchedAt),
            windows: windows,
            headlineID: "session",
            weeklyID: "weekly_all",
            plan: plan
        )
    }
}

extension CcauthOpenCodeAccount {
    var plan: String { active == true ? "Go · Ativa" : "Go" }

    /// Mesmos ids e rótulos do `OpenCodeUsage`.
    var windows: [LimitWindow] {
        guard let quota else { return [] }
        let candidates: [(id: String, label: String, window: CcauthWindow?, duration: TimeInterval?)] = [
            ("rolling", L10n.t("5h limit"), quota.rolling, 5 * 3600),
            ("weekly", L10n.t("Weekly limit"), quota.weekly, 7 * 86_400),
            ("monthly", L10n.t("Monthly limit"), quota.monthly, nil),
        ]
        return candidates.compactMap {
            ccauthLimitWindow(id: $0.id, label: $0.label, window: $0.window, duration: $0.duration)
        }
    }

    func snapshot(providerID: String) throws -> ProviderSnapshot {
        let windows = self.windows
        guard !windows.isEmpty else {
            // Chave rejeitada não é falha de leitura: pede login de novo.
            throw keyInvalid == true
                ? UsageProviderError.needsAuth
                : UsageProviderError.badResponse(status: 0)
        }
        return ProviderSnapshot(
            id: providerID,
            displayName: alias,
            glyph: .opencode,
            fidelity: .official,
            status: ccauthStatus(stale: quota?.stale, fetchedAt: quota?.fetchedAt),
            windows: windows,
            headlineID: "rolling",
            weeklyID: "weekly",
            plan: plan
        )
    }
}

/// Janela `null` ou sem `used_percent` some do anel.
private func ccauthLimitWindow(id: String, label: String, window: CcauthWindow?,
                               duration: TimeInterval?) -> LimitWindow? {
    guard let percent = window?.usedPercent else { return nil }
    return LimitWindow(id: id, label: label, usedFraction: percent / 100,
                       resetsAt: window?.resetsAt, duration: duration)
}

/// Cota velha só vira `.stale` quando se sabe desde quando; sem `fetched_at`
/// não há data para mostrar e a leitura segue como `.ok`.
private func ccauthStatus(stale: Bool?, fetchedAt: Date?) -> ProviderStatus {
    guard stale == true, let fetchedAt else { return .ok }
    return .stale(since: fetchedAt)
}

