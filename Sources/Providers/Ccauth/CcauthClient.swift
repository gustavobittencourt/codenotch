
import Combine
import Foundation

enum CcauthError: Error, Equatable, LocalizedError {
    case notInstalled
    case timedOut
    case unsupportedSchema(Int?)
    /// O ccauth respondeu, mas com falha; o texto é dele.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "ccauth não encontrado (procurei em /opt/homebrew/bin, ~/.local/bin, /usr/local/bin e /usr/bin)"
        case .timedOut:
            return "ccauth demorou demais para responder"
        case .unsupportedSchema(let schema):
            return "ccauth respondeu no schema \(schema.map(String.init) ?? "?"); o Codenotch lê o schema 2 (atualize o ccauth)"
        case .failed(let message):
            return message
        }
    }
}

/// Fala com a CLI `ccauth`: lê o status de todas as contas e troca a ativa.
///
/// Um cliente só para o app inteiro. Cada anel pergunta pelo status, mas a
/// leitura é uma só: chamadas concorrentes esperam a mesma execução e o
/// resultado vale por 20 s.
final class CcauthClient: @unchecked Sendable {
    /// Roda `ccauth <args>` e devolve stdout e o código de saída. Lança
    /// `CcauthError` quando não consegue executar ou estoura `timeout`.
    typealias Runner = (_ args: [String], _ timeout: TimeInterval) async throws -> (stdout: Data, exit: Int32)

    static let shared = CcauthClient()

    private static let cacheLifetime: TimeInterval = 20

    private let runner: Runner
    private let now: () -> Date
    private let lock = NSLock()
    private var cached: (status: CcauthStatus, at: Date)?
    private var inflight: Task<CcauthStatus, Error>?
    /// Sobe a cada `invalidate()`: uma leitura que começou antes não grava
    /// no cache o que já nasceu velho.
    private var generation = 0
    private var latest: CcauthStatus?
    private let latestSubject = CurrentValueSubject<CcauthStatus?, Never>(nil)

    init(runner: @escaping Runner = CcauthClient.runInstalledBinary, now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.now = now
    }

    /// O último status lido, para o menu montar os itens sem `await`.
    var lastStatus: CcauthStatus? { lock.withLock { latest } }

    /// Emite o status mais recente a quem assina e a cada leitura que o muda
    /// (por exemplo, a conta ativa trocou). Leitura idêntica à anterior não
    /// emite, para quem escuta não refazer trabalho à toa.
    var statusPublisher: AnyPublisher<CcauthStatus, Never> {
        latestSubject.compactMap { $0 }.removeDuplicates().eraseToAnyPublisher()
    }

    func status() async throws -> CcauthStatus {
        enum Pending {
            case ready(CcauthStatus)
            case running(Task<CcauthStatus, Error>)
        }
        let pending: Pending = lock.withLock {
            if let cached, now().timeIntervalSince(cached.at) < Self.cacheLifetime {
                return .ready(cached.status)
            }
            if let inflight { return .running(inflight) }
            let started = generation
            let task = Task { [runner] () throws -> CcauthStatus in
                let status: CcauthStatus
                do {
                    status = try await Self.read(
                        ["status", "--json", "--max-age", "60", "--lock-wait", "30"], timeout: 60, runner: runner)
                } catch {
                    // Falha não é guardada: a próxima chamada tenta de novo.
                    self.lock.withLock { if self.generation == started { self.inflight = nil } }
                    throw error
                }
                var merged = status
                let recorded: Bool = self.lock.withLock {
                    guard self.generation == started else { return false }
                    self.cached = (status, self.now())
                    merged = status.keepingLastGoodFamilies(from: self.latest)
                    self.latest = merged
                    self.inflight = nil
                    return true
                }
                // Fora do lock: quem assina pode ler `lastStatus` de dentro do sink.
                if recorded { self.latestSubject.send(merged) }
                return status
            }
            inflight = task
            return .running(task)
        }
        switch pending {
        case .ready(let status): return status
        case .running(let task): return try await task.value
        }
    }

    /// Esquece o cache e solta a leitura em andamento (ela termina para quem já
    /// espera, mas não vira cache).
    func invalidate() {
        lock.withLock {
            generation += 1
            cached = nil
            inflight = nil
        }
    }

    /// A descoberta de contas na abertura do app, antes de existir o primeiro
    /// anel: bloqueia até o ccauth responder. Sem cota (`--no-usage`), por isso
    /// alimenta só `lastStatus` e nunca o cache que `status()` reaproveita.
    func discoverAccountsSync() -> CcauthStatus? {
        let box = DiscoveryBox()
        let semaphore = DispatchSemaphore(value: 0)
        let runner = self.runner
        Task.detached {
            box.status = try? await Self.read(
                ["status", "--json", "--no-usage", "--lock-wait", "10"], timeout: 30, runner: runner)
            semaphore.signal()
        }
        // O runner já tem o próprio timeout; esta folga só evita travar a abertura
        // se ele não o respeitar.
        guard semaphore.wait(timeout: .now() + 40) == .success, let status = box.status else { return nil }
        lock.withLock { latest = status }
        latestSubject.send(status)
        return status
    }

    func switchAccount(family: CcauthFamily, alias: String) async -> Result<Void, CcauthError> {
        defer { invalidate() }
        do {
            let output = try await runner([family.rawValue, "switch", alias, "--json", "--lock-wait", "30"], 120)
            let json = Self.jsonObject(output.stdout)
            if json?["ok"] as? Bool == true { return .success(()) }
            if let message = json?["error"] as? String, !message.isEmpty {
                return .failure(.failed(message))
            }
            return .failure(.failed(Self.fallbackMessage(output)))
        } catch let error as CcauthError {
            return .failure(error)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    // MARK: - Leitura e interpretação

    private final class DiscoveryBox: @unchecked Sendable {
        var status: CcauthStatus?
    }

    private static func read(_ args: [String], timeout: TimeInterval, runner: Runner) async throws -> CcauthStatus {
        let output = try await runner(args, timeout)
        guard let json = jsonObject(output.stdout) else {
            throw CcauthError.failed(fallbackMessage(output))
        }
        if json["ok"] as? Bool == false, let message = json["error"] as? String, !message.isEmpty {
            throw CcauthError.failed(message)
        }
        guard json["schema"] as? Int == 2 else {
            throw CcauthError.unsupportedSchema(json["schema"] as? Int)
        }
        do {
            return try CcauthStatus.decode(output.stdout)
        } catch {
            throw CcauthError.failed("saída inesperada do ccauth: \(error.localizedDescription)")
        }
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Sem JSON utilizável, a última linha da saída costuma ser a explicação.
    private static func fallbackMessage(_ output: (stdout: Data, exit: Int32)) -> String {
        let text = String(decoding: output.stdout, as: UTF8.self)
        let last = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return last ?? "ccauth sem saída utilizável (código \(output.exit))"
    }

    // MARK: - Processo real

    /// O app de interface não herda o PATH do shell. Sem USER/LOGNAME o `claude`
    /// filho do ccauth responde "Not logged in".
    static func environment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let home = base["HOME"] ?? NSHomeDirectory()
        var env = ["PATH": searchDirectories(home: home).joined(separator: ":"), "HOME": home]
        env["USER"] = base["USER"] ?? NSUserName()
        env["LOGNAME"] = base["LOGNAME"] ?? env["USER"]
        return env
    }

    private static func searchDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "\(home)/.local/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    static func locateBinary(in directories: [String]? = nil) -> URL? {
        let directories = directories ?? searchDirectories(home: environment()["HOME"] ?? NSHomeDirectory())
        return directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent("ccauth") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static let runInstalledBinary: Runner = { args, timeout in
        guard let binary = locateBinary() else { throw CcauthError.notInstalled }
        return try await runProcess(executable: binary, arguments: args, environment: environment(), timeout: timeout)
    }

    /// Executa o processo fora do pool cooperativo (a leitura bloqueia) e o
    /// encerra com `terminate()` se passar de `timeout`.
    static func runProcess(executable: URL, arguments: [String], environment: [String: String],
                           timeout: TimeInterval) async throws -> (stdout: Data, exit: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runProcessBlocking(
                        executable: executable, arguments: arguments, environment: environment, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runProcessBlocking(executable: URL, arguments: [String], environment: [String: String],
                                           timeout: TimeInterval) throws -> (stdout: Data, exit: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CcauthError.failed("ccauth não executou: \(error.localizedDescription)")
        }

        let flag = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            flag.withLock { timedOut = true }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        if flag.withLock({ timedOut }) { throw CcauthError.timedOut }
        return (data, process.terminationStatus)
    }
}

