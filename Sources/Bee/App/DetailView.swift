import BeeCore
import SwiftUI

/// Routes the sidebar selection to its page.
struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.selection {
            case .request(let id):
                if let session = model.session(for: id) {
                    RequestWorkspaceView(session: session)
                        .id(id)
                } else {
                    EmptyDetailView()
                }
            case .folder(let id):
                FolderPageView(folderID: id).id(id)
            case .collection(let id):
                CollectionPageView(collectionID: id).id(id)
            case .environment(let id):
                EnvironmentPageView(environmentID: id).id(id)
            case .globals:
                GlobalsPageView()
            case .history:
                HistoryPageView()
            case nil:
                EmptyDetailView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }
}

/// One request and its response: the request line at full width, then two facing pages split by
/// the hairline. When the window is narrow, or the person prefers it, the response stacks below.
struct RequestWorkspaceView: View {
    @Environment(AppModel.self) private var model
    let session: RequestSession

    var body: some View {
        let isFork = model.fork(id: session.id) != nil
        GeometryReader { proxy in
            let facing = model.settings.responseLayout == .beside
                && proxy.size.width >= Theme.Layout.facingPagesMinWidth
            VStack(spacing: 0) {
                RequestLineView(session: session)
                if facing {
                    HStack(spacing: 0) {
                        RequestPageView(session: session)
                            .frame(width: proxy.size.width / 2)
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        ResponsePageView(session: session)
                    }
                } else {
                    VStack(spacing: 0) {
                        RequestPageView(session: session)
                            .frame(height: max((proxy.size.height - 96) * 0.45, 160))
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        ResponsePageView(session: session)
                    }
                }
            }
        }
        // A fork is not the request of the collection: its page has another ground, edge to edge,
        // and a rule down its leading edge.
        .background(isFork ? Theme.forkPaper : Theme.paper)
        .overlay(alignment: .leading) {
            if isFork {
                Rectangle()
                    .fill(Theme.forkInk)
                    .frame(width: Theme.Layout.forkRule)
                    .accessibilityHidden(true)
            }
        }
    }
}
