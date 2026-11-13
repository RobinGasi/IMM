import IMMDesign
import SwiftUI

/// The main window's content: sidebar, toolbar, scrolling screen, and the panel overlay.
public struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let sidebarWidth = IMMLayout.sidebarWidth(windowWidth: width)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: sidebarWidth)
                    VStack(spacing: 0) {
                        ToolbarView()
                        MainContent(route: model.route)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .allowsHitTesting(model.panel == nil)

                PanelHost(windowSize: proxy.size, sidebarWidth: sidebarWidth)
            }
            .environment(\.immWindowWidth, width)
        }
        .frame(minWidth: 1024, minHeight: 720)
        .background(IMMColor.background)
        .ignoresSafeArea()
        .background(WindowChrome(.main))
        .background(WindowBridge())
    }
}

/// The detail area under the toolbar: a vertical `ScrollView` (the content scrolls whenever it does not
/// fit), except for screens that scroll themselves.
private struct MainContent: View {
    let route: MainRoute

    var body: some View {
        GeometryReader { proxy in
            Group {
                if route.managesOwnScrolling {
                    RouteView(route: route)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                } else {
                    ScrollView(.vertical) {
                        RouteView(route: route)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .background(IMMColor.background)
        }
    }
}
