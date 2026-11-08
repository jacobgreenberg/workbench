import AppKit
import WebKit

/// A `.web` pane: one web page (a localhost dashboard, say) in the split tree, focusable like a terminal so ⌘W closes it.
/// Links that leave the page's own host open in the browser. A page that cannot load shows a short note with Try Again.
@MainActor final class WebPaneView: WKWebView, WKNavigationDelegate {
    let paneID: PaneID
    let address: String
    var onFocus: ((PaneID) -> Void)?
    var onTitle: (() -> Void)?
    private var titleWatch: NSKeyValueObservation?

    init(id: PaneID, url: String, background: NSColor) {
        paneID = id
        address = url
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // a dashboard needs no cookies or cache kept on disk
        super.init(frame: .zero, configuration: config)
        underPageBackgroundColor = background
        setValue(false, forKey: "drawsBackground")   // no white flash before the page paints its own background
        navigationDelegate = self
        titleWatch = observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.onTitle?() } }
        URL(string: url).map { _ = load(URLRequest(url: $0, cachePolicy: .reloadIgnoringLocalCacheData)) }
    }

    /// ⌘R: the page fresh from the server, or the address again after the unreachable note.
    func reloadPage() {
        if url?.absoluteString == address { reloadFromOrigin() } else { URL(string: address).map { _ = load(URLRequest(url: $0, cachePolicy: .reloadIgnoringLocalCacheData)) } }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let inPane = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        if inPane, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "r" {
            reloadPage()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(paneID) }
        return ok
    }

    func close() {
        titleWatch = nil
        stopLoading()
        navigationDelegate = nil
        loadHTMLString("", baseURL: nil)   // stops the page's own timers
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url,
              url.host != URL(string: address)?.host else { return .allow }
        if ["http", "https"].contains(url.scheme?.lowercased()) { NSWorkspace.shared.open(url) }   // never file: or app schemes
        return .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadHTMLString(Self.unreachable(address, error.localizedDescription), baseURL: URL(string: address))
    }

    nonisolated static func unreachable(_ url: String, _ reason: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <html><body style="font: 13px -apple-system; color: #8a8a8a; background: transparent; display: flex; height: 90vh;
        align-items: center; justify-content: center; text-align: center">
        <div><div style="font-size: 15px; color: #c8c8c8">Nothing is answering at \(esc(url))</div>
        <p>\(esc(reason))</p><a href="\(esc(url))" style="color: #6FD3E8">Try again</a></div></body></html>
        """
    }
}

#if DEBUG
@MainActor func webPaneSelfCheck() {
    let page = WebPaneView.unreachable("http://x/?a=1&b=<2>", "refused \"now\"")
    assert(page.contains("http://x/?a=1&amp;b=&lt;2>") && !page.contains("<2>") && page.contains("refused &quot;now&quot;"))
    let tree = SplitNode.leaf(PaneSpec(id: UUID(), kind: .web(url: "http://127.0.0.1:4747")))
    let back = try! JSONDecoder().decode(SplitNode.self, from: JSONEncoder().encode(tree))
    assert(back == tree)
    assert(WorkspaceController.isWebURL("http://127.0.0.1:4747") && WorkspaceController.isWebURL("HTTPS://a.b/x"))
    assert(!WorkspaceController.isWebURL("file:///etc/passwd") && !WorkspaceController.isWebURL("127.0.0.1:4747") && !WorkspaceController.isWebURL("http://"))
    print("webPaneSelfCheck ok")
}
#endif
