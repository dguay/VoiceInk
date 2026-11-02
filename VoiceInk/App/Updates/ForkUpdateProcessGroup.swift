import Darwin
import Foundation

/// A helper process started as the leader of its own process group, so the
/// watchdog and Cancel can stop it together with every git, xcodebuild, and
/// compiler process it started.
final class ForkUpdateProcessGroup: @unchecked Sendable {
    enum StopReason: Equatable, Sendable {
        case timedOut
        case cancelled
    }

    struct SupervisionResult: Equatable, Sendable {
        /// The helper's exit status, or 128 + signal when a signal ended it.
        let exitStatus: Int32
        let stopReason: StopReason?
    }

    let processIdentifier: pid_t

    private init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    /// Starts the helper with stdin from /dev/null, stdout and stderr appended to
    /// `outputPath`, and no other inherited file descriptors.
    static func launch(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        outputPath: String,
        qualityOfService: qos_class_t
    ) throws -> ForkUpdateProcessGroup {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                    | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
            )
        )
        posix_spawnattr_setpgroup(&attributes, 0)
        // Dispatch worker threads block most signals, and a spawned process
        // inherits that mask. Start the helper with nothing blocked and default
        // dispositions so SIGTERM reaches it and its cleanup trap runs.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_set_qos_class_np(&attributes, qualityOfService)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &fileActions,
            1,
            outputPath,
            O_WRONLY | O_CREAT | O_APPEND,
            0o600
        )
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        let argumentPointers = ([executablePath] + arguments).map { strdup($0) } + [nil]
        let environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }

        var processIdentifier: pid_t = 0
        let status = posix_spawn(
            &processIdentifier,
            executablePath,
            &fileActions,
            &attributes,
            argumentPointers,
            environmentPointers
        )
        guard status == 0 else {
            throw ForkUpdateError(
                message: "VoiceInk could not start its update helper: \(String(cString: strerror(status)))."
            )
        }
        return ForkUpdateProcessGroup(processIdentifier: processIdentifier)
    }

    /// Waits for the helper to exit, calling `poll` on every interval. When the
    /// watchdog expires or the calling task is cancelled, sends SIGTERM to the
    /// group so the helper can clean up, then SIGKILL after the grace period.
    /// Any process the helper left in its group is killed once it exits.
    func supervise(
        _ supervision: ProcessForkUpdateCommandRunner.Supervision,
        poll: () -> Void
    ) async -> SupervisionResult {
        let startedAt = Date()
        var stopReason: StopReason?
        var terminationRequestedAt: Date?

        while !hasExited() {
            poll()
            if let terminationRequestedAt {
                if Date().timeIntervalSince(terminationRequestedAt) >= supervision.terminationGracePeriod {
                    signalGroup(SIGKILL)
                }
            } else {
                if Task.isCancelled {
                    stopReason = .cancelled
                } else if Date().timeIntervalSince(startedAt) >= supervision.watchdogTimeout {
                    stopReason = .timedOut
                }
                if stopReason != nil {
                    signalGroup(SIGTERM)
                    terminationRequestedAt = Date()
                }
            }
            await Self.pause(supervision.pollInterval)
        }
        poll()
        // The exited leader is not reaped yet, so its process group ID cannot
        // be reused; anything still in the group belongs to this helper.
        signalGroup(SIGKILL)
        return SupervisionResult(exitStatus: reap(), stopReason: stopReason)
    }

    private func hasExited() -> Bool {
        var information = siginfo_t()
        let result = waitid(
            P_PID,
            id_t(processIdentifier),
            &information,
            WEXITED | WNOHANG | WNOWAIT
        )
        if result == -1 {
            return errno != EINTR
        }
        return information.si_pid == processIdentifier
    }

    private func signalGroup(_ signal: Int32) {
        _ = kill(-processIdentifier, signal)
    }

    private func reap() -> Int32 {
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) == -1 {
            guard errno == EINTR else { return 1 }
        }
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }

    /// Sleeps without throwing, so a cancelled task keeps supervising the
    /// helper until it has stopped.
    private static func pause(_ interval: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
                continuation.resume()
            }
        }
    }
}
