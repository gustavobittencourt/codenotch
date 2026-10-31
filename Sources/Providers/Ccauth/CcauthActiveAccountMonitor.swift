
import Combine
import Foundation

/// Mantém ligado o monitor de sessões do perfil padrão enquanto algum anel do
/// ccauth o usa. O coordenador só inicia o monitor de um id conectado, e o anel
/// nativo "claude" (dono desse monitor) deixa de existir quando o ccauth assume,
/// então alguém tem de iniciá-lo.
@MainActor
final class CcauthBaseLease {
    private let base: any AgentActivityMonitor
    private var holders = 0

    init(base: any AgentActivityMonitor) {
        self.base = base
    }

    func acquire() {
        holders += 1
        if holders == 1 { base.start() }
    }

    func release() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { base.stop() }
    }
}

/// O aviso "trabalhando/esperando" de um anel do ccauth.
///
/// As sessões do Claude Code moram todas no diretório do perfil padrão, seja
/// qual for a conta ativa. Repassa as do `base` só enquanto o alias é a conta
/// ativa do ccauth; senão, nenhuma. Reage tanto ao `base` quanto à troca de
/// conta ativa no status.
@MainActor
final class CcauthActiveAccountMonitor: AgentActivityMonitor {
    private let base: any AgentActivityMonitor
    private let family: CcauthFamily
    private let alias: String
    private let client: CcauthClient
    private let lease: CcauthBaseLease?
    private var holdsLease = false

    init(base: any AgentActivityMonitor, family: CcauthFamily, alias: String,
         client: CcauthClient = .shared, lease: CcauthBaseLease? = nil) {
        self.base = base
        self.family = family
        self.alias = alias
        self.client = client
        self.lease = lease
    }

    var sessions: [AgentSession] { isActive(client.lastStatus) ? base.sessions : [] }

    var sessionsPublisher: AnyPublisher<[AgentSession], Never> {
        let family = self.family, alias = self.alias
        let active = client.statusPublisher
            .map { $0.activeAlias(family: family) == alias }
            .removeDuplicates()
        return Publishers.CombineLatest(base.sessionsPublisher, active)
            .map { sessions, isActive in isActive ? sessions : [] }
            .eraseToAnyPublisher()
    }

    func start() {
        guard let lease, !holdsLease else { return }
        holdsLease = true
        lease.acquire()
    }

    func stop() {
        guard let lease, holdsLease else { return }
        holdsLease = false
        lease.release()
    }

    private func isActive(_ status: CcauthStatus?) -> Bool {
        status?.activeAlias(family: family) == alias
    }
}

