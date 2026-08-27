import Foundation
import Testing
@testable import VoiceInk

@Suite(.serialized)
struct ForkUpdateReliabilityTests {
    @Test
    func preparationFailureCarriesStructuredAttemptContext() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let resultPath = "$VOICEINK_UPDATE_RESULT_PATH"
        let script = """
        #!/bin/bash
        /usr/bin/plutil -create xml1 "\(resultPath)"
        /usr/bin/plutil -insert outcome -string failure "\(resultPath)"
        /usr/bin/plutil -insert stage -string merge "\(resultPath)"
        /usr/bin/plutil -insert kind -string deterministic "\(resultPath)"
        /usr/bin/plutil -insert message -string 'The candidate conflicts with upstream.' "\(resultPath)"
        /usr/bin/plutil -insert candidateIdentifier -string '1111111111111111111111111111111111111111:2222222222222222222222222222222222222222' "\(resultPath)"
        /usr/bin/plutil -insert forkCommit -string 1111111111111111111111111111111111111111 "\(resultPath)"
        /usr/bin/plutil -insert upstreamCommit -string 2222222222222222222222222222222222222222 "\(resultPath)"
        /usr/bin/plutil -insert repositoryPath -string /Users/tester/git/VoiceInk "\(resultPath)"
        /usr/bin/plutil -insert originRepository -string https://build-user:origin-secret@github.com/dguay/VoiceInk.git "\(resultPath)"
        /usr/bin/plutil -insert upstreamRepository -string https://github_pat_abcdefghijklmnopqrstuvwxyz@github.com/Beingpax/VoiceInk.git "\(resultPath)"
        /usr/bin/plutil -insert conflicts -json '["VoiceInk/Services/ForkUpdater.swift"]' "\(resultPath)"
        printf 'token=super-secret\nmerge conflict\n' >&2
        exit 1
        """
        let scriptURL = temporaryDirectory.appendingPathComponent("prepare-local-update.sh")
        try Data(script.utf8).write(to: scriptURL)
        let runner = ProcessForkUpdateCommandRunner(retryDelays: [])

        do {
            _ = try await runner.run(
                scriptURL: scriptURL,
                manifestURL: temporaryDirectory.appendingPathComponent("staged-candidate.plist"),
                installedForkCommit: "0000000000000000000000000000000000000000",
                mode: .manual
            )
            Issue.record("Expected the updater command to fail")
        } catch let failure as ForkUpdateFailure {
            let context = try #require(failure.attemptContext)
            #expect(context.repositoryPath == "/Users/tester/git/VoiceInk")
            #expect(context.originRepository == "https://[REDACTED]@github.com/dguay/VoiceInk.git")
            #expect(context.upstreamRepository == "https://[REDACTED]@github.com/Beingpax/VoiceInk.git")
            #expect(context.installedForkCommit == "0000000000000000000000000000000000000000")
            #expect(context.forkCommit == "1111111111111111111111111111111111111111")
            #expect(context.upstreamCommit == "2222222222222222222222222222222222222222")
            #expect(context.stage == .merge)
            #expect(context.conflicts == ["VoiceInk/Services/ForkUpdater.swift"])
            #expect(context.logs == ["token=[REDACTED]\nmerge conflict"])
        }
    }

    @Test
    func transientNetworkFailureRetriesWithinTheBound() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let scriptURL = temporaryDirectory.appendingPathComponent("prepare-local-update.sh")
        let attemptsURL = temporaryDirectory.appendingPathComponent("attempts")
        let forkCommit = "0123456789abcdef0123456789abcdef01234567"
        let upstreamCommit = "fedcba9876543210fedcba9876543210fedcba98"
        let script = """
            #!/usr/bin/env bash
            set -euo pipefail
            attempts_file="$(dirname "$0")/attempts"
            attempts=0
            [[ ! -f "$attempts_file" ]] || attempts="$(< "$attempts_file")"
            attempts=$((attempts + 1))
            printf '%s' "$attempts" > "$attempts_file"
            if [[ "$attempts" -lt 3 ]]; then
                printf 'fatal: unable to access repository: Could not resolve host\n' >&2
                exit 1
            fi
            printf 'fetch\nmerge\n' > "$VOICEINK_UPDATE_PROGRESS_PATH"
            /usr/bin/plutil -create xml1 "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert outcome -string upToDate "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert forkCommit -string \(forkCommit) "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert upstreamCommit -string \(upstreamCommit) "$VOICEINK_UPDATE_RESULT_PATH"
            """
        try Data(script.utf8).write(to: scriptURL)
        let delays = DelayRecorder()
        let logger = ForkUpdateLogRecorder()

        let result = try await ProcessForkUpdateCommandRunner(
            retryDelays: [1, 2],
            sleep: { delay in await delays.record(delay) },
            logger: logger
        ).run(
            scriptURL: scriptURL,
            manifestURL: temporaryDirectory.appendingPathComponent("staged-candidate.plist"),
            installedForkCommit: nil,
            mode: .automatic(deferBuild: false)
        )

        #expect(
            result == .upToDate(
                SourceProvenance(forkCommit: forkCommit, upstreamCommit: upstreamCommit)
            )
        )
        #expect(try String(contentsOf: attemptsURL, encoding: .utf8) == "3")
        #expect(await delays.values == [1, 2])
        let records = await logger.records
        #expect(records.contains { $0.stage == .fetch && $0.outcome == .succeeded })
        #expect(records.contains { $0.stage == .merge && $0.outcome == .succeeded })
    }

    @Test
    func deterministicFetchFailureIsNotRetried() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let scriptURL = temporaryDirectory.appendingPathComponent("prepare-local-update.sh")
        let attemptsURL = temporaryDirectory.appendingPathComponent("attempts")
        let forkCommit = "0123456789abcdef0123456789abcdef01234567"
        let upstreamCommit = "fedcba9876543210fedcba9876543210fedcba98"
        let script = """
            #!/usr/bin/env bash
            attempts_file="$(dirname "$0")/attempts"
            attempts=0
            [[ ! -f "$attempts_file" ]] || attempts="$(< "$attempts_file")"
            printf '%s' "$((attempts + 1))" > "$attempts_file"
            /usr/bin/plutil -create xml1 "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert outcome -string failure "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert stage -string fetch "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert message -string 'VoiceInk could not fetch origin/main.' "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert candidateIdentifier -string \(forkCommit):\(upstreamCommit) "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert forkCommit -string \(forkCommit) "$VOICEINK_UPDATE_RESULT_PATH"
            /usr/bin/plutil -insert upstreamCommit -string \(upstreamCommit) "$VOICEINK_UPDATE_RESULT_PATH"
            printf 'fatal: Authentication failed for repository\n' >&2
            exit 1
            """
        try Data(script.utf8).write(to: scriptURL)
        let delays = DelayRecorder()
        let logger = ForkUpdateLogRecorder()

        do {
            _ = try await ProcessForkUpdateCommandRunner(
                retryDelays: [1, 2],
                sleep: { delay in await delays.record(delay) },
                logger: logger
            ).run(
                scriptURL: scriptURL,
                manifestURL: temporaryDirectory.appendingPathComponent("staged-candidate.plist"),
                installedForkCommit: nil,
                mode: .automatic(deferBuild: false)
            )
            Issue.record("Expected a deterministic fetch failure")
        } catch let failure as ForkUpdateFailure {
            #expect(failure.stage == .fetch)
            #expect(failure.kind == .deterministic)
        }

        #expect(try String(contentsOf: attemptsURL, encoding: .utf8) == "1")
        #expect(await delays.values.isEmpty)
        let records = await logger.records
        #expect(records.last?.outcome == .failed)
        #expect(records.last?.forkCommit == forkCommit)
        #expect(records.last?.upstreamCommit == upstreamCommit)
    }

    @Test
    func transientInstallationFailureRetriesOnlyWhileTheParentIsAlive() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let scriptURL = temporaryDirectory.appendingPathComponent("install-local-update.sh")
        let attemptsURL = temporaryDirectory.appendingPathComponent("attempts")
        let script = """
            #!/usr/bin/env bash
            attempts_file="$(dirname "$0")/attempts"
            attempts=0
            [[ ! -f "$attempts_file" ]] || attempts="$(< "$attempts_file")"
            attempts=$((attempts + 1))
            printf '%s' "$attempts" > "$attempts_file"
            if [[ "$attempts" -lt 3 ]]; then
                printf 'fatal: connection reset while fetching origin/main\n' >&2
                exit 1
            fi
            exit 0
            """
        try Data(script.utf8).write(to: scriptURL)
        let delays = DelayRecorder()
        let logger = ForkUpdateLogRecorder()
        let candidate = StagedForkCandidate(
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            bundleURL: temporaryDirectory.appendingPathComponent("VoiceInk.app"),
            preparedAt: Date()
        )

        let outcome = try await ProcessForkUpdateInstallationRunner(
            retryDelays: [1, 2],
            sleep: { delay in await delays.record(delay) },
            logger: logger
        ).install(
            ForkUpdateInstallationRequest(
                scriptURL: scriptURL,
                candidate: candidate,
                manifestURL: temporaryDirectory.appendingPathComponent("manifest.plist"),
                targetBundleURL: temporaryDirectory.appendingPathComponent("Target.app"),
                backupBundleURL: temporaryDirectory.appendingPathComponent("Backup.app"),
                parentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                credentialGeneration: UUID().uuidString.lowercased()
            )
        )

        #expect(outcome == .completed)
        #expect(try String(contentsOf: attemptsURL, encoding: .utf8) == "3")
        #expect(await delays.values == [1, 2])
        #expect(await logger.records.filter { $0.outcome == .retrying }.count == 2)
    }

    @Test
    func transientInstallationFailureDoesNotRetryAfterParentExit() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let scriptURL = temporaryDirectory.appendingPathComponent("install-local-update.sh")
        let attemptsURL = temporaryDirectory.appendingPathComponent("attempts")
        let script = """
            #!/usr/bin/env bash
            attempts_file="$(dirname "$0")/attempts"
            attempts=0
            [[ ! -f "$attempts_file" ]] || attempts="$(< "$attempts_file")"
            printf '%s' "$((attempts + 1))" > "$attempts_file"
            printf 'fatal: connection reset while publishing origin/main\n' >&2
            exit 1
            """
        try Data(script.utf8).write(to: scriptURL)
        let delays = DelayRecorder()
        let candidate = StagedForkCandidate(
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            bundleURL: temporaryDirectory.appendingPathComponent("VoiceInk.app"),
            preparedAt: Date()
        )

        do {
            _ = try await ProcessForkUpdateInstallationRunner(
                retryDelays: [1, 2],
                sleep: { delay in await delays.record(delay) }
            ).install(
                ForkUpdateInstallationRequest(
                    scriptURL: scriptURL,
                    candidate: candidate,
                    manifestURL: temporaryDirectory.appendingPathComponent("manifest.plist"),
                    targetBundleURL: temporaryDirectory.appendingPathComponent("Target.app"),
                    backupBundleURL: temporaryDirectory.appendingPathComponent("Backup.app"),
                    parentProcessIdentifier: Int32.max,
                    credentialGeneration: UUID().uuidString.lowercased()
                )
            )
            Issue.record("Expected the detached installation failure")
        } catch let failure as ForkUpdateFailure {
            #expect(failure.kind == .transient)
        }

        #expect(try String(contentsOf: attemptsURL, encoding: .utf8) == "1")
        #expect(await delays.values.isEmpty)
    }

    @Test
    func incompatibleToolchainIsReportedWithoutRetrying() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let scriptURL = temporaryDirectory.appendingPathComponent("prepare-local-update.sh")
        let attemptsURL = temporaryDirectory.appendingPathComponent("attempts")
        let script = """
            #!/usr/bin/env bash
            attempts_file="$(dirname "$0")/attempts"
            attempts=0
            [[ ! -f "$attempts_file" ]] || attempts="$(< "$attempts_file")"
            printf '%s' "$((attempts + 1))" > "$attempts_file"
            printf 'xcode-select: error: tool xcodebuild requires Xcode 27\n' >&2
            exit 1
            """
        try Data(script.utf8).write(to: scriptURL)

        do {
            _ = try await ProcessForkUpdateCommandRunner(
                retryDelays: [0, 0],
                sleep: { _ in }
            ).run(
                scriptURL: scriptURL,
                manifestURL: temporaryDirectory.appendingPathComponent("staged-candidate.plist"),
                installedForkCommit: nil,
                mode: .manual
            )
            Issue.record("Expected an incompatible toolchain failure")
        } catch let failure as ForkUpdateFailure {
            #expect(failure.stage == .toolchain)
            #expect(failure.recoverySuggestion.contains("Install or upgrade Xcode manually"))
        }

        #expect(try String(contentsOf: attemptsURL, encoding: .utf8) == "1")
    }

    @Test
    func postTerminationOutcomeIsImportedBeforeRelaunch() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let updaterDirectory = temporaryDirectory.appendingPathComponent("Updater", isDirectory: true)
        let logDirectory = updaterDirectory.appendingPathComponent("Logs", isDirectory: true)
        let reportURL = updaterDirectory.appendingPathComponent("install-result.plist")
        let report = LocalUpdateInstallationOutcomeReport(
            attemptIdentifier: "installation-candidate",
            candidateIdentifier: "candidate",
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            outcome: .failed,
            failureStage: .permission,
            failureKind: .deterministic,
            message: "The installed app lost microphone permission after replacement.",
            rollbackOutcome: .succeeded
        )
        try FileManager.default.createDirectory(at: updaterDirectory, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(report).write(to: reportURL)

        try LocalUpdateInstallationOutcomeRecorder(
            updaterDirectoryURL: updaterDirectory,
            logDirectoryURL: logDirectory
        ).consume(reportAt: reportURL)

        let failure = try PropertyListDecoder().decode(
            ForkUpdateFailure.self,
            from: Data(contentsOf: updaterDirectory.appendingPathComponent("failure-state.plist"))
        )
        let rollback = try PropertyListDecoder().decode(
            LocalUpdateRollbackNotice.self,
            from: Data(contentsOf: updaterDirectory.appendingPathComponent("rollback-state.plist"))
        )
        let records = await ForkUpdateLogStore(directoryURL: logDirectory).loadRecords()

        #expect(failure.stage == .permission)
        #expect(rollback.outcome == .succeeded)
        #expect(records.contains { $0.stage == .permission && $0.outcome == .failed })
        #expect(records.contains { $0.stage == .rollback && $0.outcome == .succeeded })
        #expect(!FileManager.default.fileExists(atPath: reportURL.path))
    }

    @Test
    func corruptPendingOutcomeIsQuarantinedWithoutBlockingLaunch() throws {
        let updaterDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logDirectory = updaterDirectory.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: updaterDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: updaterDirectory) }
        let reportURL = updaterDirectory.appendingPathComponent("install-result.plist")
        try Data("not a property list".utf8).write(to: reportURL)
        let recorder = LocalUpdateInstallationOutcomeRecorder(
            updaterDirectoryURL: updaterDirectory,
            logDirectoryURL: logDirectory
        )

        recorder.consumePendingForLaunch()

        #expect(!FileManager.default.fileExists(atPath: reportURL.path))
        #expect(FileManager.default.fileExists(
            atPath: updaterDirectory.appendingPathComponent("install-result.invalid.plist").path
        ))
    }

    @Test
    func manualRollbackOutcomeIsImportedAndClearsTheSupersededFailure() async throws {
        let updaterDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logDirectory = updaterDirectory.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: updaterDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: updaterDirectory) }
        let reportURL = updaterDirectory.appendingPathComponent("rollback-result.plist")
        let failureURL = updaterDirectory.appendingPathComponent("failure-state.plist")
        try Data("superseded".utf8).write(to: failureURL)
        let report = LocalUpdateRollbackOutcomeReport(
            attemptIdentifier: "rollback-candidate",
            candidateIdentifier: "candidate",
            forkCommit: "candidate",
            upstreamCommit: "upstream",
            outcome: .succeeded,
            message: nil,
            initiator: .manual
        )
        try PropertyListEncoder().encode(report).write(to: reportURL)
        let recorder = LocalUpdateInstallationOutcomeRecorder(
            updaterDirectoryURL: updaterDirectory,
            logDirectoryURL: logDirectory
        )

        try recorder.consumeRollback(reportAt: reportURL)

        let notice = try PropertyListDecoder().decode(
            LocalUpdateRollbackNotice.self,
            from: Data(contentsOf: updaterDirectory.appendingPathComponent("rollback-state.plist"))
        )
        let records = await ForkUpdateLogStore(directoryURL: logDirectory).loadRecords()
        #expect(notice.initiator == .manual)
        #expect(records.contains { $0.stage == .rollback && $0.outcome == .succeeded })
        #expect(!FileManager.default.fileExists(atPath: failureURL.path))
        #expect(!FileManager.default.fileExists(atPath: reportURL.path))
    }

    @Test
    func commonTransientGitAndDependencyFailuresAreRetried() {
        let messages = [
            "RPC failed; HTTP 503 curl 22",
            "fetch-pack: unexpected disconnect while reading sideband packet",
            "fatal: early EOF",
            "Failed to clone repository because the connection was refused",
        ]

        for message in messages {
            #expect(ForkUpdateFailure.classify(message: message).kind == .transient)
        }
    }

    @Test
    func updateLogsRedactSensitiveFieldsAndRetainTheNewestUnresolvedFailure() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let now = Date(timeIntervalSince1970: 1_787_400_000)
        let logger = ForkUpdateLogStore(
            directoryURL: temporaryDirectory,
            now: { now },
            maximumAge: 30 * 24 * 60 * 60,
            maximumBytes: 6_000
        )
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: now.addingTimeInterval(-31 * 24 * 60 * 60),
                attemptIdentifier: "expired",
                stage: .fetch,
                outcome: .failed,
                candidateIdentifier: nil,
                forkCommit: nil,
                upstreamCommit: nil,
                retry: 2,
                message: "expired"
            )
        )
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: now,
                attemptIdentifier: "unresolved",
                stage: .permission,
                outcome: .failed,
                candidateIdentifier: "candidate-1",
                forkCommit: "0123456789abcdef0123456789abcdef01234567",
                upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
                retry: 1,
                message: "transcript=very private phrase\nselectedText=multi word selection\nclipboard=copied phrase\nscreenshot=private image\nAuthorization: Bearer api-secret\nhttps://voiceink:git-password@example.com/repo\nghp_abcdefghijklmnopqrstuvwxyz123456"
            )
        )
        for index in 0 ..< 6 {
            await logger.record(
                ForkUpdateLogRecord(
                    timestamp: now.addingTimeInterval(TimeInterval(index + 1)),
                    attemptIdentifier: "resolved-\(index)",
                    stage: .build,
                    outcome: .succeeded,
                    candidateIdentifier: "candidate-\(index + 2)",
                    forkCommit: nil,
                    upstreamCommit: nil,
                    retry: nil,
                    message: String(repeating: "build evidence ", count: 45)
                )
            )
        }

        let records = await logger.loadRecords()
        let storedText = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        let storedBytes = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(0) { total, url in
            total + ((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        #expect(!records.contains { $0.attemptIdentifier == "expired" })
        #expect(records.contains { $0.attemptIdentifier == "unresolved" && $0.retry == 1 })
        #expect(!storedText.contains("api-secret"))
        #expect(!storedText.contains("private"))
        #expect(!storedText.contains("phrase"))
        #expect(!storedText.contains("selection"))
        #expect(!storedText.contains("clipboard=copy"))
        #expect(!storedText.contains("screenshot=image"))
        #expect(!storedText.contains("git-password"))
        #expect(!storedText.contains("ghp_"))
        #expect(storedBytes <= 6_000)
    }

    @Test
    func failedAttemptContextPersistsRecoveryEvidenceWithRedactedLogs() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = ForkUpdateAttemptContextStore(directoryURL: temporaryDirectory)
        let context = ForkUpdateAttemptContext(
            attemptIdentifier: "attempt-14",
            repositoryPath: "/Users/tester/git/VoiceInk",
            originRepository: "https://build-user:origin-secret@github.com/dguay/VoiceInk.git",
            upstreamRepository: "https://github_pat_abcdefghijklmnopqrstuvwxyz@github.com/Beingpax/VoiceInk.git",
            installedForkCommit: "0000000000000000000000000000000000000000",
            forkCommit: "1111111111111111111111111111111111111111",
            upstreamCommit: "2222222222222222222222222222222222222222",
            stage: .merge,
            conflicts: ["VoiceInk/Services/ForkUpdater.swift"],
            logs: ["merge failed token=super-secret", "selectedText=private words"]
        )

        let contextURL = try store.persist(context)
        let persisted = try store.load()
        let storedText = try String(contentsOf: contextURL, encoding: .utf8)

        #expect(persisted.attemptIdentifier == "attempt-14")
        #expect(persisted.repositoryPath == "/Users/tester/git/VoiceInk")
        #expect(persisted.originRepository == "https://[REDACTED]@github.com/dguay/VoiceInk.git")
        #expect(persisted.upstreamRepository == "https://[REDACTED]@github.com/Beingpax/VoiceInk.git")
        #expect(persisted.installedForkCommit == "0000000000000000000000000000000000000000")
        #expect(persisted.forkCommit == "1111111111111111111111111111111111111111")
        #expect(persisted.upstreamCommit == "2222222222222222222222222222222222222222")
        #expect(persisted.stage == .merge)
        #expect(persisted.conflicts == ["VoiceInk/Services/ForkUpdater.swift"])
        #expect(persisted.logs == ["merge failed token=[REDACTED]", "selectedText=[REDACTED]"])
        #expect(!storedText.contains("super-secret"))
        #expect(!storedText.contains("private words"))
        #expect(!storedText.contains("origin-secret"))
        #expect(!storedText.contains("github_pat_"))
    }

    @Test @MainActor
    func persistentFailureKeepsItsAttemptContextAndClearsItAfterRecovery() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let contextStore = ForkUpdateAttemptContextStore(directoryURL: temporaryDirectory)
        let context = ForkUpdateAttemptContext(
            attemptIdentifier: "attempt-14",
            repositoryPath: "/Users/tester/git/VoiceInk",
            originRepository: "dguay/VoiceInk",
            upstreamRepository: "Beingpax/VoiceInk",
            installedForkCommit: nil,
            forkCommit: "1111111111111111111111111111111111111111",
            upstreamCommit: "2222222222222222222222222222222222222222",
            stage: .test,
            conflicts: [],
            logs: ["VoiceInk updater tests failed."]
        )
        let failure = ForkUpdateFailure(
            stage: .test,
            kind: .deterministic,
            candidateIdentifier: "candidate",
            message: "VoiceInk updater tests failed.",
            recoverySuggestion: "Fix the tests, then resume the update.",
            attemptContext: context
        )
        let transaction = ForkUpdateTransaction(
            scriptURL: temporaryDirectory.appendingPathComponent("prepare-local-update.sh"),
            manifestURL: temporaryDirectory.appendingPathComponent("staged-candidate.plist"),
            attemptContextStore: contextStore
        )

        try transaction.persistFailure(failure)

        #expect(try transaction.loadPersistentFailure() == failure)
        #expect(try contextStore.load() == context)

        try transaction.clearPersistentFailure()

        #expect(try transaction.loadPersistentFailure() == nil)
        #expect(!FileManager.default.fileExists(atPath: contextStore.contextURL.path))
    }

    @Test
    func logRetentionPreservesAnUnresolvedPreflightFailureWithoutACandidate() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let now = Date(timeIntervalSince1970: 1_787_400_000)
        let logger = ForkUpdateLogStore(
            directoryURL: temporaryDirectory,
            now: { now },
            maximumAge: 1,
            maximumBytes: 2_048
        )
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: now.addingTimeInterval(-60),
                attemptIdentifier: "preflight-failure",
                stage: .fetch,
                outcome: .failed,
                candidateIdentifier: nil,
                forkCommit: nil,
                upstreamCommit: nil,
                retry: 2,
                message: "The fork could not be reached."
            )
        )

        let records = await logger.loadRecords()

        #expect(records.contains { $0.attemptIdentifier == "preflight-failure" })
    }

    @Test
    func successInAnotherStageDoesNotResolveAProtectedFailure() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let now = Date(timeIntervalSince1970: 1_787_400_000)
        let logger = ForkUpdateLogStore(
            directoryURL: temporaryDirectory,
            now: { now },
            maximumBytes: 350
        )
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: now,
                attemptIdentifier: "unresolved-build",
                stage: .build,
                outcome: .failed,
                candidateIdentifier: "candidate",
                forkCommit: "fork",
                upstreamCommit: "upstream",
                retry: nil,
                message: "The build failed."
            )
        )
        await logger.record(
            ForkUpdateLogRecord(
                timestamp: now.addingTimeInterval(1),
                attemptIdentifier: "later-fetch",
                stage: .fetch,
                outcome: .succeeded,
                candidateIdentifier: "candidate",
                forkCommit: "fork",
                upstreamCommit: "upstream",
                retry: nil,
                message: nil
            )
        )

        let records = await logger.loadRecords()

        #expect(records.contains { $0.attemptIdentifier == "unresolved-build" })
    }

    @Test
    func corruptLogFilesCannotBypassTheSizeCap() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Data(repeating: 0x41, count: 4_096).write(
            to: temporaryDirectory.appendingPathComponent("attempt-corrupt.jsonl")
        )
        let logger = ForkUpdateLogStore(
            directoryURL: temporaryDirectory,
            maximumAge: 30 * 24 * 60 * 60,
            maximumBytes: 2_048
        )

        await logger.record(
            ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: "valid",
                stage: .fetch,
                outcome: .failed,
                candidateIdentifier: nil,
                forkCommit: nil,
                upstreamCommit: nil,
                retry: 2,
                message: "Network unavailable."
            )
        )

        let storedBytes = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(0) { total, url in
            total + ((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        #expect(storedBytes <= 2_048)
        #expect(await logger.loadRecords().contains { $0.attemptIdentifier == "valid" })
    }

    @Test
    func appendingToACorruptBundlePreservesTheNewFailureRecord() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Data([0xFF, 0xFE, 0xFD]).write(
            to: temporaryDirectory.appendingPathComponent("attempt-protected.jsonl")
        )
        let logger = ForkUpdateLogStore(directoryURL: temporaryDirectory, maximumBytes: 2_048)

        await logger.record(
            ForkUpdateLogRecord(
                timestamp: Date(),
                attemptIdentifier: "protected",
                stage: .installation,
                outcome: .failed,
                candidateIdentifier: "candidate",
                forkCommit: "candidate",
                upstreamCommit: "upstream",
                retry: nil,
                message: "Installation failed."
            )
        )

        #expect(await logger.loadRecords().contains {
            $0.attemptIdentifier == "protected" && $0.outcome == .failed
        })
    }

    @Test
    func oversizedProtectedBundleIsCompactedWithoutLosingItsFailure() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let protectedURL = temporaryDirectory.appendingPathComponent("attempt-protected.jsonl")
        var oversized = Data()
        for index in 0 ..< 20 {
            let record = ForkUpdateLogRecord(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                attemptIdentifier: "protected",
                stage: .build,
                outcome: index == 19 ? .failed : .retrying,
                candidateIdentifier: "candidate",
                forkCommit: nil,
                upstreamCommit: nil,
                retry: index,
                message: String(repeating: "evidence ", count: 20)
            )
            oversized.append(try JSONEncoder().encode(record))
            oversized.append(0x0A)
        }
        try oversized.write(to: protectedURL)
        let logger = ForkUpdateLogStore(directoryURL: temporaryDirectory, maximumBytes: 2_048)

        await logger.record(
            ForkUpdateLogRecord(
                timestamp: Date(timeIntervalSince1970: 21),
                attemptIdentifier: "other",
                stage: .fetch,
                outcome: .succeeded,
                candidateIdentifier: "other",
                forkCommit: nil,
                upstreamCommit: nil,
                retry: nil,
                message: nil
            )
        )

        let storedBytes = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(0) { total, url in
            total + ((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        #expect(storedBytes <= 2_048)
        #expect(await logger.loadRecords().contains {
            $0.attemptIdentifier == "protected" && $0.outcome == .failed
        })
    }

    @Test @MainActor
    func persistentFailureTakesPrecedenceOverAStagedCandidateOnRelaunch() {
        let candidate = StagedForkCandidate(
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_000)
        )
        let failure = ForkUpdateFailure.reported(
            stage: .installation,
            kind: .deterministic,
            candidateIdentifier: candidate.forkCommit,
            message: "The previous installation attempt failed."
        )
        let adapter = ForkUpdaterAdapter(
            transaction: ForkUpdateStartupTransactionStub(candidate: candidate, failure: failure)
        )
        var presentedFailure: ForkUpdateFailure?
        var presentedCandidate = false
        adapter.onEvent = { event in
            switch event {
            case .preparationFailed(let receivedFailure):
                presentedFailure = receivedFailure
            case .stagedCandidate:
                presentedCandidate = true
            default:
                break
            }
        }

        adapter.start()

        #expect(presentedFailure == failure)
        #expect(!presentedCandidate)
    }

    @Test @MainActor
    func updaterDeduplicatesActionableCandidateFailureAndRollbackNotifications() {
        let suiteName = "ForkUpdateReliabilityTests.notifications"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = ReliabilityUpdaterAdapterStub()
        let notifications = ForkUpdateNotificationRecorder()
        let logOpener = ForkUpdateLogOpenerRecorder()
        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: adapter,
            notificationDeliverer: notifications,
            logOpener: logOpener
        )
        let candidate = StagedForkCandidate(
            forkCommit: "0123456789abcdef0123456789abcdef01234567",
            upstreamCommit: "fedcba9876543210fedcba9876543210fedcba98",
            bundleURL: URL(fileURLWithPath: "/tmp/VoiceInk.app"),
            preparedAt: Date(timeIntervalSince1970: 1_787_400_000)
        )
        let failure = ForkUpdateFailure(
            stage: .permission,
            kind: .deterministic,
            candidateIdentifier: candidate.forkCommit,
            message: "Accessibility permission no longer matches the previous app.",
            recoverySuggestion: "Review permissions and restore if needed."
        )

        adapter.send(.stagedCandidate(candidate))
        adapter.send(.stagedCandidate(candidate))
        adapter.send(.preparationFailed(failure))
        adapter.send(.preparationFailed(failure))
        #expect(updater.state.failure == failure)
        adapter.send(.rollbackCompleted)

        #expect(
            notifications.notifications.map(\.kind)
                == [.candidateReady, .permissionRegression, .rollbackSucceeded]
        )
        #expect(updater.state.failure == nil)

        updater.openUpdateLogs()
        updater.checkForUpdates()

        #expect(logOpener.openCount == 1)
        #expect(adapter.updateCheckCount == 1)
        #expect(updater.state.failure == nil)
    }

    @Test @MainActor
    func automaticRollbackNotificationKeepsTheActionablePrimaryFailure() {
        let suiteName = "ForkUpdateReliabilityTests.automatic-rollback"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = ReliabilityUpdaterAdapterStub()
        let notifications = ForkUpdateNotificationRecorder()
        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: adapter,
            notificationDeliverer: notifications
        )
        let failure = ForkUpdateFailure.reported(
            stage: .permission,
            kind: .deterministic,
            candidateIdentifier: "candidate",
            message: "VoiceInk lost microphone permission."
        )

        adapter.send(.preparationFailed(failure))
        adapter.send(
            .rollbackReported(
                LocalUpdateRollbackNotice(
                    candidateIdentifier: "candidate",
                    outcome: .succeeded,
                    initiator: .automatic
                )
            )
        )

        #expect(notifications.notifications.map(\.kind) == [.permissionRegression, .rollbackSucceeded])
        #expect(updater.state.failure == failure)
    }

    @Test @MainActor
    func manualRollbackNotificationClearsTheSupersededPrimaryFailure() {
        let suiteName = "ForkUpdateReliabilityTests.manual-rollback"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = ReliabilityUpdaterAdapterStub()
        let notifications = ForkUpdateNotificationRecorder()
        let updater: any UpdaterModule = UpdaterViewModel(
            defaults: defaults,
            adapter: adapter,
            notificationDeliverer: notifications
        )
        let failure = ForkUpdateFailure.reported(
            stage: .permission,
            kind: .deterministic,
            candidateIdentifier: "candidate",
            message: "VoiceInk lost microphone permission."
        )

        adapter.send(.preparationFailed(failure))
        adapter.send(
            .rollbackReported(
                LocalUpdateRollbackNotice(
                    candidateIdentifier: "candidate",
                    outcome: .succeeded,
                    initiator: .manual
                )
            )
        )

        #expect(notifications.notifications.map(\.kind) == [.permissionRegression, .rollbackSucceeded])
        #expect(notifications.notifications.last?.title == "VoiceInk restored the previous version.")
        #expect(updater.state.failure == nil)
    }
}

private actor DelayRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        values.append(value)
    }
}

private actor ForkUpdateLogRecorder: ForkUpdateLogging {
    private(set) var records: [ForkUpdateLogRecord] = []

    func record(_ record: ForkUpdateLogRecord) {
        records.append(record)
    }
}

@MainActor
private final class ForkUpdateStartupTransactionStub: ForkUpdateTransacting {
    let candidate: StagedForkCandidate
    let failure: ForkUpdateFailure
    var canRestorePreviousVersion = false

    init(candidate: StagedForkCandidate, failure: ForkUpdateFailure) {
        self.candidate = candidate
        self.failure = failure
    }

    func loadStagedCandidate() throws -> StagedForkCandidate? { candidate }
    func loadPersistentFailure() throws -> ForkUpdateFailure? { failure }
    func prepare(mode: ForkUpdatePreparationMode) async throws -> ForkUpdatePreparationResult {
        .staged(candidate)
    }
    func requestRestart(for candidate: StagedForkCandidate) async throws -> StagedForkCandidate? { nil }
    func restorePreviousVersion() async throws {}
}

@MainActor
private final class ReliabilityUpdaterAdapterStub: UpdaterAdapter {
    var state = UpdaterAdapterState(
        canCheckForUpdates: true,
        sessionInProgress: false,
        lastUpdateCheckDate: nil,
        updateCheckInterval: 24 * 60 * 60
    )
    var onEvent: ((UpdaterAdapterEvent) -> Void)?
    var canRestorePreviousVersion = true
    private(set) var updateCheckCount = 0

    func start() {}
    func checkForUpdateInformation() {}
    func checkForUpdates() { updateCheckCount += 1 }
    func requestRestart(for candidate: StagedForkCandidate) {}
    func restorePreviousVersion() {}
    func send(_ event: UpdaterAdapterEvent) { onEvent?(event) }
}

@MainActor
private final class ForkUpdateNotificationRecorder: ForkUpdateNotificationDelivering {
    private(set) var notifications: [ForkUpdateUserNotification] = []

    func deliver(_ notification: ForkUpdateUserNotification, action: @escaping () -> Void) {
        notifications.append(notification)
    }
}

@MainActor
private final class ForkUpdateLogOpenerRecorder: ForkUpdateLogOpening {
    private(set) var openCount = 0

    func openLogs() {
        openCount += 1
    }
}
