import ApplicationActions
import SuiteDomain
import SwiftUI

struct AccountsView: View {
    @Bindable var model: AccountsModel
    @State private var sheet: SheetKind?
    @State private var confirmRemoval: AccountID?

    enum SheetKind: Identifiable {
        case add
        case signIn(AccountSummary)
        var id: String {
            switch self {
            case .add: "add"
            case .signIn(let account): account.id.rawValue.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar {
                Text("Accounts")
            } trailing: {
                Button("Add Account…") { sheet = .add }.buttonStyle(.arenaPill)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Each account has its own sign-in, journal and web profile.").foregroundStyle(.secondary)
                    VStack(spacing: 10) {
                        if model.loading && model.accounts.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Checking saved sessions…").foregroundStyle(.secondary)
                            }
                        } else if model.accounts.isEmpty {
                            Text("No accounts yet. Add your Arena account to start archiving your history.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(model.accounts) { account in
                            row(account)
                        }
                    }
                    if let message = model.message {
                        Text(message).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Text("Read-only archiver. Your password is sent to Arena once and never stored; session cookies are kept in your Keychain.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle("Accounts")
        .sheet(item: $sheet) { kind in
            switch kind {
            case .add:
                SignInSheet(title: "Add Arena Account", asksForName: true) { name, email, password in
                    await model.add(name: name, email: email, password: password)
                }
            case .signIn(let account):
                SignInSheet(title: "Sign In to “\(account.displayName)”", asksForName: false) { _, email, password in
                    await model.signInAgain(account.id, email: email, password: password)
                }
            }
        }
        .task { await model.start() }
    }

    @ViewBuilder private func row(_ account: AccountSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AccountBadge(
                text: String(account.displayName.prefix(1)).uppercased(), size: 32,
                active: model.syncing[account.id] != nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName)
                HStack(spacing: 6) {
                    Circle().fill(Self.color(account.state)).frame(width: 6, height: 6)
                    Text(Self.label(account.state)).foregroundStyle(.secondary)
                }
                .font(Theme.caption)
                if let progress = model.syncing[account.id] {
                    Text(Self.describe(progress)).font(Theme.caption).foregroundStyle(.secondary)
                } else if let manifest = model.lastSync[account.id] {
                    Text(Self.describe(manifest)).font(Theme.caption)
                        .foregroundStyle(manifest.outcome == .completed ? Color.secondary : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.syncErrors[account.id] {
                    Text(error).font(Theme.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if model.working.contains(account.id) {
                    ProgressView().controlSize(.small)
                } else if confirmRemoval == account.id {
                    Text("Remove from this Mac?").font(Theme.caption)
                    Button("Remove", role: .destructive) {
                        confirmRemoval = nil
                        Task { await model.remove(account.id) }
                    }
                    Button("Cancel") { confirmRemoval = nil }
                } else {
                    if model.syncing[account.id] != nil {
                        ProgressView().controlSize(.small)
                        Button("Stop") { Task { await model.cancelSync(account.id) } }
                    } else if account.state == .signedIn {
                        Button("Sync History") { Task { await model.syncHistory(account.id) } }
                    }
                    if model.syncing[account.id] != nil {
                        EmptyView()
                    } else if account.state == .signedIn || account.state == .unreachable || account.state == .blocked {
                        Button("Verify") { Task { await model.verify(account.id) } }
                    } else {
                        Button("Sign In…") { sheet = .signIn(account) }
                    }
                    Button("Remove…") { confirmRemoval = account.id }
                }
            }
            .buttonStyle(.arenaPill)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sunken.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .accessibilityElement(children: .combine)
    }

    static func describe(_ progress: SyncProgress) -> String {
        switch progress.stage {
        case .verifying: "Verifying identity…"
        case .listing: "Listing history: \(progress.pages) page(s), \(progress.entries) conversations…"
        case .details: "Archiving conversations: \(progress.detailsDone) of \(progress.detailsNeeded)…"
        case .finishing: "Finishing…"
        }
    }

    static func describe(_ manifest: SyncManifest) -> String {
        let counts = "\(manifest.entriesListed) listed, \(manifest.detailsFetched) archived, \(manifest.detailsUnchanged) unchanged"
            + (manifest.detailsAbsent > 0 ? ", \(manifest.detailsAbsent) no longer on Arena" : "")
            + (manifest.detailsFailed > 0 ? ", \(manifest.detailsFailed) failed" : "")
        switch manifest.outcome {
        case .completed: return "Last sync complete (observed pagination): " + counts
        case .partial: return "Last sync stopped (\(manifest.reason ?? "unknown")); resumable. " + counts
        case .blocked: return "Last sync blocked by Arena (\(manifest.reason ?? "")). Nothing retried."
        case .needsSignIn: return "Last sync needs a new sign-in."
        case .sessionReplaced: return "Last sync stopped: account signed in again during sync."
        case .cancelled: return "Last sync stopped by you; resumable. " + counts
        case .storageFailed: return "Last sync stopped: the archive could not be written."
        }
    }

    static func label(_ state: AccountAuthState) -> String {
        switch state {
        case .unverified: "Checking…"
        case .signedIn: "Signed in"
        case .needsSignIn: "Sign in needed"
        case .quarantined: "Identity mismatch — session discarded. Sign in again."
        case .unreachable: "Arena unreachable — will retry on Verify"
        case .blocked: "Arena blocked the request — nothing retried; try Verify later"
        }
    }

    static func color(_ state: AccountAuthState) -> Color {
        switch state {
        case .signedIn: .green
        case .quarantined: .red
        case .needsSignIn, .unreachable, .blocked: .orange
        case .unverified: .secondary
        }
    }
}

private struct SignInSheet: View {
    let title: String
    let asksForName: Bool
    let submit: (String, String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.heading)
            if asksForName {
                ArenaField(symbol: "person") { TextField("Name on this Mac (optional)", text: $name) }
            }
            ArenaField(symbol: "envelope") { TextField("Arena email", text: $email).textContentType(.username) }
            ArenaField(symbol: "key") { SecureField("Arena password", text: $password).textContentType(.password) }
            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In") {
                    let submitted = password
                    password = ""
                    working = true
                    Task {
                        let succeeded = await submit(name, email, submitted)
                        working = false
                        if succeeded { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || email.isEmpty || password.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
        .buttonStyle(.arenaPill)
        .departureMono()
        .arenaPalette()
    }
}
