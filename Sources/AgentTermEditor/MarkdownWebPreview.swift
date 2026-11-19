import MarkdownUI
import SwiftUI
import WebKit

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// A rendered Markdown document (#126, decided by the owner on 2026-11-19):
/// the Markdown as HTML (MarkdownUI's own renderer, cmark's, which leaves
/// out any raw HTML of the file) in a web view, laid out and scrolled in
/// WebKit's process, so that a long document holds nothing up. GitHub's
/// look in the dark, code coloured by highlight.js (Highlightr's copy) and
/// diagrams drawn by Mermaid, in the page. Nothing of the file runs: the
/// page's only scripts are those three, by a nonce. Links open where the
/// app opens them; pictures next to the document are read from disk.
public struct MarkdownPreview: View {
    let text: String
    /// Folder of the document, so links and images relative to it resolve.
    let baseURL: URL?
    @Environment(\.openURL) private var openURL

    public init(text: String, baseURL: URL?) {
        self.text = text
        self.baseURL = baseURL
    }

    public var body: some View {
        MarkdownWebView(text: text, baseURL: baseURL) { openURL($0) }
            .background(Color(EditorStyle.background))
            .accessibilityIdentifier("markdown-preview")
    }

    /// The page for a document: what WebKit is given.
    public static func page(for text: String, baseURL: URL?, nonce: String) -> String {
        // HTML mixed into the Markdown that has a Markdown meaning is turned
        // into it first, as the preview always did.
        let body = MarkdownContent(MarkdownHTML.flatten(text)).renderHTML()
        let mermaid = body.contains("language-mermaid") ? WebPreviewAssets.mermaid : nil
        var page = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data: https: http:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            """
        if let baseURL { page += "<base href=\"\(escapeAttribute(baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"))\">" }
        page += "<style>\(WebPreviewAssets.style)</style>"
        if let theme = WebPreviewAssets.codeTheme { page += "<style>\(theme)</style>" }
        page += "</head><body><article class=\"markdown-body\">\(body)</article>"
        if let highlight = WebPreviewAssets.highlight { page += "<script nonce=\"\(nonce)\">\(highlight)</script>" }
        if let mermaid { page += "<script nonce=\"\(nonce)\">\(mermaid)</script>" }
        page += "<script nonce=\"\(nonce)\">\(WebPreviewAssets.start)</script></body></html>"
        return page
    }

    private static func escapeAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }
}

/// What every page of the preview is made with, read once.
enum WebPreviewAssets {
    /// highlight.js, from Highlightr's resources, wherever they were put.
    static let highlight: String? = resource("highlight.min", "js")
    static let codeTheme: String? = resource(Highlighting.theme + ".min", "css")
    static let mermaid: String? = {
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// Highlightr's bundle is the app's, or next to the program in a build
    /// without one.
    private static func resource(_ name: String, _ type: String) -> String? {
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            let candidates = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for bundle in candidates where bundle.lastPathComponent.contains("Highlightr") && bundle.pathExtension == "bundle" {
                if let url = Bundle(url: bundle)?.url(forResource: name, withExtension: type), let text = try? String(contentsOf: url, encoding: .utf8) {
                    return text
                }
            }
        }
        return nil
    }

    /// Colours the code, draws the diagrams, and keeps a picture's width.
    static let start = """
        for (const code of document.querySelectorAll('pre > code')) {
          const language = [...code.classList].find(c => c.startsWith('language-'));
          if (language === 'language-mermaid' && window.mermaid) {
            const box = document.createElement('div');
            box.className = 'mermaid';
            box.textContent = code.textContent;
            code.parentElement.replaceWith(box);
          } else if (window.hljs) {
            hljs.highlightElement(code);
          }
        }
        if (window.mermaid) {
          mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'dark' });
          mermaid.run({ querySelector: '.mermaid' });
        }
        for (const img of document.querySelectorAll('img')) {
          const width = /#agentterm-width=(\\d+)/.exec(img.getAttribute('src') || '');
          if (width) img.style.width = width[1] + 'px';
        }
        """

    /// GitHub's look, in the editor's dark.
    static let style = """
        :root { color-scheme: dark; }
        html, body { margin: 0; background: #1b1d22; }
        .markdown-body { color: #dbdbdb; font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; padding: 16px 20px 40px; max-width: 980px; word-wrap: break-word; }
        .markdown-body a { color: #4c8dff; text-decoration: none; }
        .markdown-body a:hover { text-decoration: underline; }
        .markdown-body h1, .markdown-body h2 { border-bottom: 1px solid #3a3d44; padding-bottom: .3em; }
        .markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
        .markdown-body h1 { font-size: 2em; } .markdown-body h2 { font-size: 1.5em; } .markdown-body h3 { font-size: 1.25em; }
        .markdown-body p, .markdown-body ul, .markdown-body ol, .markdown-body table, .markdown-body pre, .markdown-body blockquote { margin: 0 0 16px; }
        .markdown-body ul, .markdown-body ol { padding-left: 2em; }
        .markdown-body code { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(255,255,255,.08); padding: .2em .4em; border-radius: 6px; }
        .markdown-body pre { background: rgba(255,255,255,.06); border-radius: 6px; padding: 14px; overflow: auto; }
        .markdown-body pre code { background: none; padding: 0; }
        .markdown-body pre code.hljs { background: none; padding: 0; }
        .markdown-body blockquote { color: #9a9ca3; border-left: .25em solid #3a3d44; padding: 0 1em; }
        .markdown-body table { border-collapse: collapse; display: block; overflow: auto; }
        .markdown-body th, .markdown-body td { border: 1px solid #3a3d44; padding: 6px 13px; }
        .markdown-body tr:nth-child(2n) { background: rgba(255,255,255,.03); }
        .markdown-body img { max-width: 100%; }
        .markdown-body hr { border: 0; border-top: 1px solid #3a3d44; margin: 24px 0; }
        .markdown-body .mermaid { margin: 0 0 16px; text-align: center; }
        """
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private typealias PreviewRepresentable = NSViewRepresentable
#else
private typealias PreviewRepresentable = UIViewRepresentable
#endif

private struct MarkdownWebView: PreviewRepresentable {
    let text: String
    let baseURL: URL?
    let open: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    private func make(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        return webView
    }

    private func update(_ webView: WKWebView, _ coordinator: Coordinator) {
        coordinator.open = open
        guard coordinator.shown != text || coordinator.base != baseURL else { return }
        coordinator.shown = text
        coordinator.base = baseURL
        coordinator.load(text: text, baseURL: baseURL, into: webView)
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context.coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context.coordinator) }
    #endif

    final class Coordinator: NSObject, WKNavigationDelegate {
        var open: (URL) -> Void
        var shown: String?
        var base: URL?
        private var page: URL?
        private var generation = 0

        init(open: @escaping (URL) -> Void) { self.open = open }

        deinit { if let page { try? FileManager.default.removeItem(at: page) } }

        /// The page is made off the main thread; a document picked meanwhile wins.
        func load(text: String, baseURL: URL?, into webView: WKWebView) {
            generation += 1
            let generation = generation
            let nonce = UUID().uuidString
            DispatchQueue.global(qos: .userInitiated).async {
                let html = MarkdownPreview.page(for: text, baseURL: baseURL, nonce: nonce)
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let self, let webView, generation == self.generation else { return }
                    if let baseURL, baseURL.isFileURL {
                        // Pictures next to the document are files: the page
                        // is one too, which may read them.
                        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-preview", isDirectory: true)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        if let page = self.page { try? FileManager.default.removeItem(at: page) }
                        let page = folder.appendingPathComponent(UUID().uuidString + ".html")
                        self.page = page
                        try? Data(html.utf8).write(to: page)
                        webView.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
                    } else {
                        webView.loadHTMLString(html, baseURL: nil)
                    }
                }
            }
        }

        /// A link opens where the app opens it; one within the page moves in it.
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
            if url.fragment != nil, url.absoluteString.hasPrefix((webView.url?.absoluteString ?? "") + "#") || url.scheme == "about" {
                return decisionHandler(.allow)
            }
            decisionHandler(.cancel)
            open(url)
        }
    }
}
