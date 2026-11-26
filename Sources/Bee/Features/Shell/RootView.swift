import BeeCore
import SwiftUI

/// The window: the sidebar and the page of what is selected.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: ShellMetrics.sidebarMinWidth, ideal: ShellMetrics.sidebarIdealWidth,
                    max: ShellMetrics.sidebarMaxWidth
                )
        } detail: {
            DetailView()
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.isVaultLocked { VaultLockedBanner() }
                }
                .overlay(alignment: .bottom) { NoticeBanner() }
                // Only its buttons answer a question: when one question takes the place of another, the sheet
                // going away says nothing of the next one.
                .sheet(item: Binding(get: { model.agents.question }, set: { _ in })) { question in
                    AgentQuestionSheet(question: question).environment(model)
                }
                .sheet(isPresented: Binding(
                    get: { ShellState.shared.mergingFork != nil },
                    set: { if !$0 { ShellState.shared.mergingFork = nil } }
                )) {
                    if let forkID = ShellState.shared.mergingFork {
                        ForkMergeSheet(forkID: forkID).environment(model)
                    }
                }
                .background(Theme.paper)
                .navigationTitle(model.selectionTitle)
                .navigationSubtitle(model.selectionBreadcrumb)
                .focusedSceneValue(\.shellFocus, model.shellFocus)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { EnvironmentMenu() }
                }
        }
    }
}

// MARK: - Environment capsule

/// The one toolbar control: which environment requests are sent with.
private struct EnvironmentMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.workspace.activeEnvironment
        let activeName = active?.name ?? "None"
        Menu {
            Picker("Environment", selection: activeBinding) {
                ForEach(model.shownEnvironments) { environment in
                    Text(environment.name).tag(Optional(environment.id))
                }
                Text("No environment").tag(UUID?.none)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if let active {
                Divider()
                Button("Edit \(active.name)") { model.selection = .environment(active.id) }
            }
        } label: {
            Text("\(Text("Environment").foregroundStyle(Theme.inkSecondary))  \(Text(activeName).fontWeight(.semibold))")
                .font(Theme.text())
                .foregroundStyle(Theme.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, Theme.Space.m)
        .help("Environment used to send requests")
        .accessibilityLabel("Environment")
        .accessibilityValue(activeName)
    }

    private var activeBinding: Binding<UUID?> {
        Binding(
            get: { model.workspace.activeEnvironmentID },
            set: { model.setActiveEnvironment($0) }
        )
    }
}

// MARK: - Banners

/// Shown above the page while the secrets cannot be read.
private struct VaultLockedBanner: View {
    @Environment(AppModel.self) private var model
    @ViewState private var isUnlocking = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "lock")
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            // No vertical `fixedSize` here: a wrapping text that refuses to shrink raises the minimum
            // height the split view measures for the column and pushes the whole window content up.
            Text("Secrets are locked. Bee could not read its key from your Keychain.")
                .font(Theme.text())
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            Spacer(minLength: Theme.Space.m)
            Button("Unlock") {
                isUnlocking = true
                Task {
                    await model.retryVaultUnlock()
                    isUnlocking = false
                }
            }
            .buttonStyle(OutlineButtonStyle())
            .disabled(isUnlocking)
        }
        .padding(.horizontal, Theme.Layout.pageInset)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity)
        .background(Theme.rowHover)
    }
}

/// The current notice, at the bottom of the page. A message leaves by itself; an error stays
/// until it is dismissed or replaced.
private struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let notice = model.notice {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    if notice.kind == .error {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Theme.negative)
                            .accessibilityLabel("Error")
                    }
                    Text(notice.message)
                        .font(Theme.text())
                        .foregroundStyle(Theme.ink)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    if notice.action == .showUpdate {
                        Button("See Update") {
                            model.notice = nil
                            openWindow(id: UpdateModel.windowID)
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(Theme.text(Theme.Size.caption, weight: .medium))
                            .frame(width: Theme.Space.l, height: Theme.Space.l)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.tokenGround, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .padding(.horizontal, Theme.Layout.pageInset)
                .padding(.bottom, Theme.Space.l)
                .frame(maxWidth: ShellMetrics.pageMaxWidth)
                .accessibilityElement(children: .contain)
            }
        }
        .task(id: model.notice?.id) {
            guard let notice = model.notice, notice.kind == .info, notice.action == nil else { return }
            try? await Task.sleep(for: ShellMetrics.noticeLifetime)
            if !Task.isCancelled, model.notice?.id == notice.id { model.notice = nil }
        }
    }
}

// MARK: - Empty page

/// The page when nothing is selected.
struct EmptyDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Text("Select a request in the sidebar, or start with a new one.")
                .font(Theme.text())
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: Theme.Space.s) {
                Button("New request") { model.newRequest() }
                Button("Import…") { ShellActions.importFromPanel(model) }
            }
            .buttonStyle(OutlineButtonStyle())
        }
        .padding(Theme.Layout.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .bottomTrailing) { CombField() }
        .clipped()
    }
}
