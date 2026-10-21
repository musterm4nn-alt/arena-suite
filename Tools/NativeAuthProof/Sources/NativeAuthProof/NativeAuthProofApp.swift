import AppKit
import NativeAuthResearch
import SwiftUI

/// Launch arguments: `--slot <A|B>` selects the Keychain research slot (default A);
/// `--phase0a` runs the Phase 0-A experiments after restore or sign-in;
/// `--isolation` restores slots A and B in this process and runs the A7 isolation check.
enum LaunchMode {
    static let arguments = CommandLine.arguments
    static var slot: String {
        guard let index = arguments.firstIndex(of: "--slot"), arguments.indices.contains(index + 1) else { return "A" }
        let value = arguments[index + 1]
        return value.allSatisfy { $0.isLetter || $0.isNumber } && !value.isEmpty ? value : "A"
    }
    static let phase0A = arguments.contains("--phase0a")
    static let isolation = arguments.contains("--isolation")
    /// `--agent-detail`: after restore or sign-in, observe one `agentic` entry's detail routes.
    static let agentDetail = arguments.contains("--agent-detail")
    /// After a verified restore, delete and re-add the Keychain item so its access control is
    /// created by this (identity-signed) build rather than inherited from an older one (A6).
    static let rekey = arguments.contains("--rekey")
}

@main
struct NativeAuthProofApp: App {
    var body: some Scene {
        WindowGroup("Arena Suite — Native Authentication Proof (slot \(LaunchMode.slot))") {
            ProofView()
        }
    }
}

private struct ProofView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var client = NativeAuthClient(sessionStore: KeychainResearchSessionStore(slot: LaunchMode.slot))
    @State private var status = "Ready. No network request has been sent."
    @State private var observedEmail: String?
    @State private var busy = false
    @State private var attempted = false
    @State private var localAuthError: LocalAuthError?
    @State private var showLocalError = false
    @State private var generation: GenerationObservation?
    @State private var generationAttempted = false
    @State private var showGenerationBytes = false
    @State private var history: HistoryObservation?
    @State private var historyDetail: HistoryDetailObservation?
    @State private var historyAttempted = false
    @State private var startupAttempted = false
    @State private var restoredSession = false
    @State private var runID = UUID().uuidString

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Native authentication feasibility").font(.title2)
            Text("Disposable research tool · direct Foundation URLSession")
                .foregroundStyle(.secondary)
            TextField("Arena email", text: $email)
                .textContentType(.username)
            SecureField("Arena password", text: $password)
                .textContentType(.password)
            if attempted && !restoredSession {
                Text(
                    "A nonempty password was supplied to the client. The field was cleared after copying it for submission."
                )
                .font(.caption)
            }
            Text(
                "One sign-in request, then identity verification. Native session cookies and expected IDs are saved in macOS Keychain; your password is not saved. Read-only history checks run automatically."
            )
            .font(.callout)
            HStack {
                Button("Test Native Sign-In") { signIn() }
                    .disabled(busy || attempted || email.isEmpty || password.isEmpty)
                Button("Recheck Identity") { recheck() }
                    .disabled(busy || observedEmail == nil)
                Button("New Isolated Session") {
                    client = NativeAuthClient(sessionStore: KeychainResearchSessionStore(slot: LaunchMode.slot))
                    password = ""
                    observedEmail = nil
                    attempted = false
                    restoredSession = false
                    localAuthError = nil
                    showLocalError = false
                    generation = nil
                    generationAttempted = false
                    showGenerationBytes = false
                    history = nil
                    historyDetail = nil
                    historyAttempted = false
                    status = "Fresh isolated session. No request sent."
                    runID = UUID().uuidString
                    report("awaitingLogin", summary: status)
                }
                .disabled(busy)
            }
            Button("Forget Saved Session") {
                Task { @MainActor in
                    busy = true
                    defer { busy = false }
                    do {
                        try await client.forgetSavedSession()
                        client = NativeAuthClient(sessionStore: KeychainResearchSessionStore(slot: LaunchMode.slot))
                        password = ""
                        observedEmail = nil
                        attempted = false
                        restoredSession = false
                        history = nil
                        historyDetail = nil
                        historyAttempted = false
                        status = "Saved Keychain session removed and active native session discarded."
                        report("awaitingLogin", summary: status)
                    } catch {
                        status = message(for: error)
                        report("failed", summary: status)
                    }
                }
            }.disabled(busy)
            if busy { ProgressView().controlSize(.small) }
            Text(status).textSelection(.enabled)
            if let localAuthError {
                Toggle("Show server error locally (may contain personal information)", isOn: $showLocalError)
                if showLocalError {
                    Text(localAuthError.serverMessage ?? "No plain-text error field was available.")
                    Text(localAuthError.interpretation).font(.caption)
                    if let verification = localAuthError.requiresVerification {
                        Text("Server requiresVerification flag: \(verification ? "true" : "false")")
                    }
                    Text(
                        "This text is not logged or exported. Do not share a screenshot of it if it contains personal information or secrets."
                    )
                    .font(.caption)
                }
            }
            if let observedEmail {
                Text("Arena identity response email: \(observedEmail)")
                Text(
                    "Check that this is your intended account. Native chat, refresh and relaunch restoration are still unverified."
                )
                .font(.callout)
                Button("Test One Native Prompt") { sendProbe() }
                    .disabled(true)
                Text(
                    "Generation is on hold after N-004: reCAPTCHA validation failed."
                )
                .font(.caption)
                Button("Inspect Native History List") { inspectHistory() }
                    .disabled(busy || historyAttempted)
                Text(
                    "Verifies identity, then reads one history page. Private contents stay in memory; only counts and status are displayed."
                )
                .font(.caption)
            }
            if let history {
                Text(history.summary).textSelection(.enabled)
            }
            if let historyDetail {
                Text(historyDetail.summary).textSelection(.enabled)
            }
            if let generation {
                let reply = generation.response
                Text(
                    "Generation HTTP \(reply.status.map(String.init) ?? "unavailable") · transport \(reply.transferEnd.rawValue) · \(reply.units.count) callback observations · \(reply.body.count) bytes retained in memory."
                )
                Text(
                    "Transport completion is not verified logical completion. No automatic retry or remote stop claim."
                )
                .font(.caption)
                Toggle("Show generation response locally (untrusted/private bytes)", isOn: $showGenerationBytes)
                if showGenerationBytes {
                    ScrollView {
                        Text(
                            String(data: reply.body.prefix(16_384), encoding: .utf8)
                                ?? "Binary/invalid UTF-8: original bytes retained in memory."
                        )
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    }.frame(minHeight: 80, maxHeight: 180)
                    Text(
                        "Preview limited to 16 KiB. Do not share secret-bearing response text. Quitting discards this research capture."
                    )
                    .font(.caption)
                }
            }
        }
        .padding(24)
        .frame(width: 620)
        .task { await restoreAndCheck() }
    }

    private func signIn() {
        guard !email.isEmpty && !password.isEmpty && !busy && !attempted else { return }
        busy = true
        attempted = true
        let submittedEmail = email
        let submittedPassword = password
        password = ""
        status = "Testing the observed sign-in contract…"
        Task { @MainActor in
            defer { busy = false }
            do {
                let identity = try await client.signIn(email: submittedEmail, password: submittedPassword)
                observedEmail = identity.email
                status = "Native sign-in HTTP 200; identity HTTP 200 with the observed ID fields."
                try await client.saveSession()
                if LaunchMode.phase0A {
                    await runPhase0A(preflight: (.notFound, 0), restored: false)
                } else if LaunchMode.agentDetail {
                    await runAgentDetail()
                } else {
                    await automaticHistory()
                }
            } catch {
                status = message(for: error)
                localAuthError = await client.errorForLocalPresentation()
                report("failed", summary: status)
            }
        }
    }

    @MainActor private func restoreAndCheck() async {
        guard !startupAttempted else { return }
        startupAttempted = true
        busy = true
        defer { busy = false }
        if LaunchMode.isolation {
            await runIsolation()
            return
        }
        let preflight = KeychainResearchSessionStore(slot: LaunchMode.slot).preflight()
        report("restoring", summary: "Attempting native Keychain session restoration.")
        do {
            guard let identity = try await client.restoreSavedSession() else {
                status = "No saved native session. Sign in once; subsequent launches will verify the saved session."
                report("awaitingLogin", summary: status)
                return
            }
            observedEmail = identity.email
            attempted = true
            restoredSession = true
            status = "Saved native session restored; both identity claims verified."
            if LaunchMode.rekey { try await client.forgetSavedSession() }
            try await client.saveSession()
            if LaunchMode.phase0A {
                await runPhase0A(preflight: preflight, restored: true)
            } else if LaunchMode.agentDetail {
                await runAgentDetail()
            } else {
                await automaticHistory()
            }
        } catch {
            observedEmail = nil
            client = NativeAuthClient()
            status = "Saved session could not be verified. Sign in manually. " + message(for: error)
            report("failed", summary: status)
        }
    }

    @MainActor private func automaticHistory() async {
        guard !historyAttempted else { return }
        historyAttempted = true
        do {
            let observation = try await client.inspectHistoryList()
            history = observation
            status = "Automatic read-only history check finished."
            report("historyObserved", summary: observation.summary)
            guard observation.response.status == 200, observation.response.transferEnd == .complete else { return }
            let detailObservation = try await client.inspectFirstHistoryDetail()
            historyDetail = detailObservation
            status = "Automatic read-only detail check finished."
            report("detailObserved", summary: detailObservation.summary)
        } catch {
            observedEmail = nil
            status = message(for: error)
            report("failed", summary: status)
        }
    }

    @MainActor private func runPhase0A(preflight: (KeychainPreflight, Int32), restored: Bool) async {
        status = "Running Phase 0-A checks (one request at a time, 1 s apart)…"
        report("phase0aRunning", summary: status)
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        let result = await Phase0ARunner.run(
            client: client,
            keychain: .init(preflight: preflight.0, preflightStatus: preflight.1, restored: restored),
            signing: .current(),
            fixtureCandidate: directory.appendingPathComponent("phase0a-detail-candidate-\(LaunchMode.slot).json"))
        writeJSON(result, to: directory.appendingPathComponent("Phase0AResult-\(LaunchMode.slot).json"))
        status = result.stoppedEarly.map { "Phase 0-A stopped: \($0)" } ?? "Phase 0-A checks finished (\(result.requestsSent) requests)."
        report(result.stoppedEarly == nil ? "phase0aFinished" : "failed", summary: status)
    }

    @MainActor private func runAgentDetail() async {
        status = "Observing one agent conversation's detail routes (one request at a time, 1 s apart)…"
        report("agentDetailRunning", summary: status)
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        let result = await AgentDetailRunner.run(
            client: client, candidate: directory.appendingPathComponent("agent-detail-candidate-\(LaunchMode.slot).html"))
        writeJSON(result, to: directory.appendingPathComponent("AgentDetailResult-\(LaunchMode.slot).json"))
        status = result.stoppedEarly.map { "Agent detail stopped: \($0)" } ?? "Agent detail observation finished (\(result.requestsSent) requests)."
        report(result.stoppedEarly == nil ? "agentDetailFinished" : "failed", summary: status)
    }

    @MainActor private func runIsolation() async {
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        let clientA = NativeAuthClient(sessionStore: KeychainResearchSessionStore(slot: "A"))
        let clientB = NativeAuthClient(sessionStore: KeychainResearchSessionStore(slot: "B"))
        status = "Restoring slots A and B for the isolation check…"
        report("isolationRunning", summary: status)
        do {
            async let restoredA = clientA.restoreSavedSession()
            async let restoredB = clientB.restoreSavedSession()
            guard let identityA = try await restoredA, let identityB = try await restoredB else {
                status = "Isolation check needs saved sessions in both slots A and B."
                report("failed", summary: status)
                return
            }
            let result = await IsolationRunner.run(
                a: clientA, identityA: identityA, b: clientB, identityB: identityB, signing: .current())
            writeJSON(result, to: directory.appendingPathComponent("IsolationResult.json"))
            status = result.stoppedEarly.map { "Isolation check stopped: \($0)" } ?? "Isolation check finished."
            report(result.stoppedEarly == nil ? "isolationFinished" : "failed", summary: status)
        } catch {
            status = "Isolation restore failed. " + message(for: error)
            report("failed", summary: status)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            status = "Could not write \(url.lastPathComponent)."
        }
    }

    /// Fixed, value-free status only: never cookies, identities, server bodies or user input.
    private func report(_ phase: String, summary: String) {
        let destination = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(
            LaunchMode.slot == "A" ? "NativeProofResult.json" : "NativeProofResult-\(LaunchMode.slot).json")
        do {
            let object = [
                "schema": "native-proof-status/1", "runID": runID,
                "updatedAt": ISO8601DateFormatter().string(from: Date()), "phase": phase, "summary": summary,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: destination, options: .atomic)
        } catch {
            status = "Could not write value-free status report. Inspect the local UI result."
        }
    }

    private func inspectHistory() {
        guard !busy && !historyAttempted && observedEmail != nil else { return }
        busy = true
        historyAttempted = true
        status = "Verifying identity, then reading one history page…"
        Task { @MainActor in
            defer { busy = false }
            do {
                history = try await client.inspectHistoryList()
                status = "Read-only history observation retained in memory."
            } catch {
                observedEmail = nil
                status = message(for: error)
            }
        }
    }

    private func recheck() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                _ = try await client.recheckIdentity()
                status = "Native identity HTTP 200; both ID claims match the prior native observation."
            } catch {
                observedEmail = nil
                status = message(for: error)
            }
        }
    }

    private func sendProbe() {
        guard !busy && !generationAttempted && observedEmail != nil else { return }
        busy = true
        generationAttempted = true
        status = "Verifying identity, then attempting one native generation…"
        Task { @MainActor in
            defer { busy = false }
            do {
                generation = try await client.testOneGeneration()
                status =
                    "Native generation attempt recorded in memory. Inspect the HTTP/transport result below; no automatic follow-up."
            } catch {
                status = "Native generation probe stopped. Remote outcome may be unknown. Do not resend automatically."
            }
        }
    }

    private func message(for error: any Error) -> String {
        switch error as? ResearchFailure {
        case .httpFailure(let step, let status):
            return
                "\(step.rawValue) returned HTTP \(status). Stopped; no automatic retry or challenge bypass. Response body omitted."
        case .identityMismatch:
            return "Identity mismatch. This proof session is quarantined; start a new isolated session."
        case .alreadyAuthenticated:
            return "This proof session is already authenticated. Use Recheck Identity."
        case .sessionStorageFailed:
            return
                "Native session storage failed. Check the Keychain prompt or sign in again. No secret details are logged."
        case .identityShapeUnverified:
            return "Identity response does not match the observed shape. Native authentication is not established."
        default:
            return "Proof could not complete. No automatic retry. Inspect the research contract before a new attempt."
        }
    }
}
