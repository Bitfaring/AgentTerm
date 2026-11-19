import SwiftUI
import WebKit
import cmark_gfm
import cmark_gfm_extensions

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
        let body = GitHubMarkdown.html(MarkdownHTML.flatten(text))
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

/// Markdown as GitHub makes it into HTML: cmark-gfm with its tables,
/// struck-through text, links found in the text and task lists. Raw HTML
/// of the file is left out, as cmark's safe default does. MarkdownUI's own
/// `renderHTML()` is not used: it builds a table's cells without their
/// spans, which cmark-gfm then takes for fillers and writes no tags for.
enum GitHubMarkdown {
    /// The extensions, registered once whichever thread asks first.
    private static let extensions: [String] = {
        cmark_gfm_core_extensions_ensure_registered()
        return ["table", "strikethrough", "autolink", "tasklist"]
    }()

    static func html(_ markdown: String) -> String {
        let names = extensions
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in names {
            if let found = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, found) }
        }
        var bytes = Array(markdown.utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) { cmark_parser_feed(parser, $0, buffer.count) }
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, CMARK_OPT_DEFAULT, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        return String(cString: html)
    }
}

/// Where the pages of a document with pictures beside it are written (#126):
/// a folder of the build's and the process's own, so that the released app
/// and a development build never touch each other's. What an app of the
/// same build that has ended left is taken away.
enum PreviewPages {
    static func folder(in temporary: URL, identifier: String, pid: Int32) -> URL {
        let manager = FileManager.default
        let prefix = "\(identifier)-preview-"
        for name in (try? manager.contentsOfDirectory(atPath: temporary.path)) ?? [] where name.hasPrefix(prefix) {
            guard let other = Int32(name.dropFirst(prefix.count)), other != pid, kill(other, 0) != 0, errno == ESRCH else { continue }
            try? manager.removeItem(at: temporary.appendingPathComponent(name))
        }
        let folder = temporary.appendingPathComponent(prefix + String(pid), isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
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
        .markdown-body li:has(> input[type="checkbox"]) { list-style: none; margin-left: -1.5em; }
        .markdown-body li > input[type="checkbox"] { margin: 0 .4em 0 0; vertical-align: middle; }
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

    /// One store for every preview, kept in memory only: a store of each
    /// view's own had WebKit start a process for each, 30 to 50 ms of the
    /// main thread every time a document was opened (#126).
    @MainActor private static let dataStore = WKWebsiteDataStore.nonPersistent()

    private func make(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
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

        static let folder = PreviewPages.folder(
            in: FileManager.default.temporaryDirectory, identifier: Bundle.main.bundleIdentifier ?? "agentterm", pid: getpid())

        /// The page is made off the main thread; a document picked meanwhile wins.
        func load(text: String, baseURL: URL?, into webView: WKWebView) {
            generation += 1
            let generation = generation
            let nonce = UUID().uuidString
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak webView] in
                let html = MarkdownPreview.page(for: text, baseURL: baseURL, nonce: nonce)
                // The folder is found here, off the main thread: the first
                // time, it looks through the temporary folder.
                let folder = baseURL?.isFileURL == true ? Self.folder : nil
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let self, let webView, generation == self.generation else { return }
                    if let folder {
                        // Pictures next to the document are files: the page
                        // is one too, which may read them.
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
