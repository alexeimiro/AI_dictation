import SwiftUI

/// The main window (1200×780 in the mock): the grey sidebar, and the page it picks on white.
/// The title bar is hidden; the traffic lights sit in the sidebar's top 52 pt.
struct MainWindow: View {
    @Bindable var model: MacAppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: Mac.Metric.sidebarWidth)
            Rectangle().fill(Mac.Palette.line).frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Mac.Palette.canvas)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 640)
        .foregroundStyle(Mac.Palette.ink)
        .environment(\.colorScheme, .light)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .word(let entry): WordSheet(model: model, entry: entry)
            case .snippet(let snippet): SnippetSheet(model: model, snippet: snippet)
            case .paywall: PaywallSheet(model: model)
            }
        }
        .task { await model.refreshAccount() }
        .onAppear { if model.openWindowAction == nil { model.openWindowAction = openWindow } }
    }

    @Environment(\.openWindow) private var openWindow

    @ViewBuilder private var page: some View {
        switch model.page {
        case .home: HomePage(model: model)
        case .notes: NotesPage(model: model)
        case .dictionary: DictionaryPage(model: model)
        case .snippets: SnippetsPage(model: model)
        case .style: StylePage(model: model)
        case .insights: InsightsPage(model: model)
        }
    }
}

/// The 52 pt strip at the top of a page: its search and actions, on the right.
struct PageBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content
        }
        .padding(.horizontal, 20)
        .frame(height: Mac.Metric.barHeight)
    }
}
