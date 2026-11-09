import AppKit
import UniformTypeIdentifiers
import WebKit

/// Live Markdown preview. The web view exists only while the preview is open, so Markdown support
/// costs nothing when unused.
///
/// The page is served from the private `tovri-preview:` scheme. Its `<base>` points at the
/// document's folder, so relative image paths resolve to `tovri-preview://file/<path>`, which
/// `PreviewResourceHandler` answers with the image from disk. A strict Content-Security-Policy
/// allows only Tovri's own script, so HTML embedded in a Markdown file can't run code.
final class MarkdownPreviewView: NSView, WKNavigationDelegate {
    static let scheme = "tovri-preview"
    private static let pageURL = URL(string: "\(scheme)://page/index.html")!

    private let webView: WKWebView
    private let messages = PreviewMessageProxy()
    private let resources = PreviewResourceHandler()
    private let remoteBar = RemoteContentBar()
    private var loaded = false
    private var pendingBody: (html: String, base: String)?
    private var pendingLine: Int?
    var onOpenFile: ((URL) -> Void)?
    /// Remote images and media can track when a document is read, so they load only on request.
    var allowsRemoteContent = Settings.shared.markdownRemoteContent
    var onRequestRemoteContent: (() -> Void)?
    /// First top-level source line visible in the preview, reported as it scrolls.
    private(set) var topLine = 0
    /// Draws the divider on the left edge when shown beside the editor.
    var showsDivider = true { didSet { needsLayout = true; needsDisplay = true } }

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(resources, forURLScheme: MarkdownPreviewView.scheme)
        config.userContentController.add(messages, name: "tovri")
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: frame, configuration: config)
        super.init(frame: frame)
        messages.onLine = { [weak self] line in self?.topLine = line }
        messages.onRemoteContentBlocked = { [weak self] in self?.remoteContentWasBlocked() }
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        addSubview(webView)
        remoteBar.isHidden = true
        remoteBar.onLoad = { [weak self] in self?.onRequestRemoteContent?() }
        addSubview(remoteBar)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tovri")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = showsDivider ? 1 : 0
        let bar = remoteBar.isHidden ? 0 : RemoteContentBar.height
        remoteBar.frame = NSRect(x: inset, y: bounds.height - bar, width: max(0, bounds.width - inset), height: bar)
        webView.frame = NSRect(x: inset, y: 0, width: max(0, bounds.width - inset), height: max(0, bounds.height - bar))
    }

    /// Called when the page blocked a remote image or video.
    func remoteContentWasBlocked() {
        guard !allowsRemoteContent, remoteBar.isHidden else { return }
        remoteBar.isHidden = false
        needsLayout = true
    }


    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.active
        theme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        if showsDivider {
            theme.chromeBorder.setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    func focus() { window?.makeFirstResponder(webView) }

    func printOperation(with info: NSPrintInfo) -> NSPrintOperation {
        let op = webView.printOperation(with: info)
        // Without a frame, WebKit's print view can paginate to blank pages.
        op.view?.frame = webView.bounds
        return op
    }

    /// URL under which files in `directory` are visible to the page.
    static func baseHref(for directory: URL?) -> String {
        guard let dir = directory else { return "\(scheme)://file/" }
        return resourceURL(forPath: dir.path + "/")?.absoluteString ?? "\(scheme)://file/"
    }

    static func resourceURL(forPath path: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "file"
        c.path = path
        return c.url
    }

    /// Loads the page shell (styles for the current theme); content is then swapped in via JS.
    func loadShell(theme: Theme, fontSize: CGFloat) {
        loaded = false
        resources.startPage()
        remoteBar.isHidden = true
        remoteBar.applyTheme(theme)
        needsLayout = true
        webView.loadHTMLString(MarkdownPreviewView.shell(theme: theme, fontSize: fontSize, allowRemote: allowsRemoteContent),
                               baseURL: MarkdownPreviewView.pageURL)
    }

    func setBody(_ html: String, baseDirectory: URL?) {
        setBody(html, base: MarkdownPreviewView.baseHref(for: baseDirectory))
    }

    private func setBody(_ html: String, base: String) {
        guard loaded else { pendingBody = (html, base); return }
        let json = (try? String(data: JSONSerialization.data(withJSONObject: [html, base]), encoding: .utf8)) ?? "[\"\",\"\"]"
        webView.evaluateJavaScript("tovriSetContent(...\(json))", completionHandler: nil)
    }

    func scroll(toLine line: Int) {
        guard loaded else { pendingLine = line; return }
        topLine = line
        webView.evaluateJavaScript("tovriScrollToLine(\(line))", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let b = pendingBody { pendingBody = nil; setBody(b.html, base: b.base) }
        if let l = pendingLine { pendingLine = nil; scroll(toLine: l) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.navigationType != .linkActivated {
            // Only the shell itself may load in the main frame; embedded HTML can't navigate away.
            decisionHandler(url == MarkdownPreviewView.pageURL || url.absoluteString == "about:blank" ? .allow : .cancel)
            return
        }
        decisionHandler(.cancel)
        switch url.scheme?.lowercased() {
        case MarkdownPreviewView.scheme?:
            guard url.host == "file" else { return }
            let file = URL(fileURLWithPath: url.path)
            let ext = file.pathExtension.lowercased()
            // Links in untrusted documents must never launch anything (apps, scripts, .terminal
            // files), so local targets go through Tovri's own opening: text, Quick Look or a folder.
            if ["md", "markdown", "mdx", "txt"].contains(ext) || FileManager.default.fileExists(atPath: file.path) {
                onOpenFile?(file)
            }
        case "http"?, "https"?, "mailto"?:
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    private static func css(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255), s.alphaComponent)
    }

    static func tokenColors(_ theme: Theme) -> [TokenKind: String] {
        var out: [TokenKind: String] = [:]
        for k in TokenKind.allCases { if let c = theme.color(k) { out[k] = css(c) } }
        return out
    }

    static func shell(theme t: Theme, fontSize: CGFloat, allowRemote: Bool) -> String {
        let remote = allowRemote ? "*" : ""
        let fg = css(t.foreground), muted = css(t.chromeSecondary), accent = css(t.color(.link) ?? t.accent)
        let border = css(t.chromeBorder), codeBg = css(t.fieldBackground), bg = t.translucent ? "transparent" : css(t.background)
        let heading = css(t.foreground), quote = css(t.chromeSecondary)
        let inserted = css(t.color(.inserted) ?? t.accent)
        let deleted = css(t.color(.deleted) ?? t.accent)
        let importantColor = css(t.color(.keyword) ?? t.accent)
        let warningColor = t.isDark ? "rgba(227,179,65,1.000)" : "rgba(154,103,0,1.000)"
        let subtleBg = css(t.foreground.withAlphaComponent(t.isDark ? 0.04 : 0.025))
        let zebraBg = css(t.foreground.withAlphaComponent(t.isDark ? 0.028 : 0.018))
        let markBg = css(t.findMatch.withAlphaComponent(t.isDark ? 0.38 : 0.45))
        let thumb = css(t.foreground.withAlphaComponent(t.isDark ? 0.26 : 0.24))
        let thumbHover = css(t.foreground.withAlphaComponent(t.isDark ? 0.42 : 0.38))
        let mono = "ui-monospace, 'SF Mono', Menlo, monospace"
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let s = scheme
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(remote) data: blob: \(s):; media-src \(remote) data: blob: \(s):; style-src 'unsafe-inline'; font-src data:; script-src 'nonce-\(nonce)'; form-action 'none'; frame-src 'none'; base-uri \(s):">
        <base id="base" href="\(s)://file/">
        <style>
        :root { color-scheme: \(t.isDark ? "dark" : "light"); --accent: \(accent); }
        html, body { background: \(bg); }
        body { margin: 0; padding: 36px 44px 30vh; color: \(fg); font: \(Int(fontSize + 2))px/1.68 -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
               -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; word-wrap: break-word; overflow-wrap: break-word; }
        #content { max-width: 860px; margin: 0 auto; }
        h1, h2, h3, h4, h5, h6 { color: \(heading); font-weight: 650; line-height: 1.28; letter-spacing: -0.012em; margin: 1.65em 0 0.6em; scroll-margin-top: 20px; }
        h1 { font-size: 2.05em; padding-bottom: .32em; border-bottom: 1px solid \(border); margin-top: .3em; letter-spacing: -0.02em; }
        h2 { font-size: 1.52em; padding-bottom: .28em; border-bottom: 1px solid \(border); }
        h3 { font-size: 1.25em; } h4 { font-size: 1.05em; } h5 { font-size: .92em; } h6 { font-size: .86em; color: \(muted); text-transform: uppercase; letter-spacing: 0.04em; }
        p, ul, ol, dl, blockquote, table, pre, details, .math-block, .toc, .front-matter { margin: 0 0 1.1em; }
        a { color: \(accent); text-decoration: none; text-underline-offset: 3px; } a:hover { text-decoration: underline; }
        strong { font-weight: 650; }
        del { color: \(muted); text-decoration-thickness: 1.5px; }
        mark { background: \(markBg); color: inherit; padding: .08em .28em; border-radius: 4px; }
        sup, sub { font-size: .76em; line-height: 0; }
        code { font-family: \(mono); font-size: .87em; background: \(codeBg); border: 1px solid \(border); padding: .14em .42em; border-radius: 5px; }
        pre { position: relative; background: \(codeBg); border: 1px solid \(border); border-radius: 9px; padding: 14px 16px; overflow-x: auto; line-height: 1.52; }
        pre[data-lang] { padding-top: 34px; }
        pre[data-lang]::before { content: attr(data-lang); position: absolute; top: 8px; left: 14px; font: 600 11px/1 \(mono); color: \(muted); text-transform: uppercase; letter-spacing: 0.05em; pointer-events: none; user-select: none; }
        pre code { background: none; border: 0; padding: 0; font-size: .86em; white-space: pre; tab-size: 4; }
        .code-copy { position: absolute; top: 6px; right: 8px; font: 500 11px/1 -apple-system, BlinkMacSystemFont, sans-serif; color: \(muted); background: \(subtleBg); border: 1px solid \(border); border-radius: 5px; padding: 4px 8px; cursor: pointer; opacity: 0; transition: opacity .14s ease, color .14s ease, background .14s ease; user-select: none; }
        pre:hover .code-copy, .code-copy:focus-visible, .code-copy.copied { opacity: 1; }
        .code-copy:hover { color: \(fg); background: \(codeBg); }
        .code-copy.copied { color: \(inserted); border-color: \(inserted); }
        blockquote { margin-left: 0; padding: .35em 1.1em; color: \(quote); border-left: 3.5px solid \(border); background: \(subtleBg); border-radius: 0 7px 7px 0; }
        blockquote > :first-child { margin-top: 0; } blockquote > :last-child { margin-bottom: 0; }
        blockquote.alert { --alert-color: \(accent); border-left: 4px solid var(--alert-color); padding: 12px 16px; color: \(fg); background: \(subtleBg); border-radius: 0 8px 8px 0; }
        .alert-title { display: flex; align-items: center; gap: 7px; font-weight: 650; color: var(--alert-color); margin: 0 0 .4em; line-height: 1.3; }
        .alert-icon { flex-shrink: 0; fill: currentColor; }
        .alert-note { --alert-color: \(accent); }
        .alert-tip { --alert-color: \(inserted); }
        .alert-important { --alert-color: \(importantColor); }
        .alert-warning { --alert-color: \(warningColor); }
        .alert-caution { --alert-color: \(deleted); }
        hr { border: 0; border-top: 1px solid \(border); margin: 2em 0; }
        table { border-collapse: separate; border-spacing: 0; display: block; width: max-content; max-width: 100%; overflow-x: auto; border: 1px solid \(border); border-radius: 8px; }
        th, td { border-right: 1px solid \(border); border-bottom: 1px solid \(border); padding: 8px 14px; }
        th:last-child, td:last-child { border-right: 0; }
        tbody tr:last-child td { border-bottom: 0; }
        th { font-weight: 650; background: \(codeBg); text-align: left; }
        tbody tr:nth-child(even) { background: \(zebraBg); }
        img, video { max-width: 100%; height: auto; } img { border-radius: 7px; }
        img[align=right] { float: right; margin-left: 1em; } img[align=left] { float: left; margin-right: 1em; }
        ul, ol { padding-left: 1.85em; } li + li { margin-top: .28em; }
        li > ul, li > ol { margin-top: .28em; margin-bottom: .28em; }
        .contains-task-list { list-style: none; padding-left: 1.4em; }
        .task-list-item input[type=checkbox] { margin: 0 .5em 0 -1.3em; vertical-align: middle; accent-color: \(accent); width: 14px; height: 14px; }
        dl { padding: 0; }
        dt { font-weight: 650; margin-top: .8em; color: \(heading); }
        dt:first-child { margin-top: 0; }
        dd { margin: .25em 0 .75em 1.4em; color: \(fg); }
        details { border: 1px solid \(border); border-radius: 8px; padding: .6em 1em; background: \(subtleBg); }
        summary { font-weight: 600; cursor: pointer; user-select: none; }
        details[open] > summary { margin-bottom: .6em; padding-bottom: .45em; border-bottom: 1px solid \(border); }
        .front-matter { font-size: .88em; }
        div.front-matter { background: \(codeBg); border: 1px solid \(border); border-radius: 8px; padding: 8px 12px; }
        div.front-matter table { border: 0; border-radius: 0; display: table; width: 100%; margin: 0; }
        div.front-matter th, div.front-matter td { border: 0; background: none !important; padding: 4px 8px; vertical-align: top; }
        div.front-matter .fm-key { width: 1%; white-space: nowrap; color: \(muted); font-family: \(mono); font-weight: 600; font-size: .92em; padding-right: 14px; }
        div.front-matter .fm-tag { display: inline-block; font-family: \(mono); font-size: .86em; background: \(subtleBg); border: 1px solid \(border); border-radius: 999px; padding: 1px 8px; margin: 1px 4px 1px 0; }
        pre.front-matter { opacity: .82; }
        .math-block { background: \(codeBg); border: 1px solid \(border); border-radius: 8px; padding: 12px 16px; overflow-x: auto; text-align: center; }
        .math-block code { background: none; border: 0; padding: 0; font-family: 'STIX Two Math', 'Cambria Math', 'Latin Modern Math', \(mono); font-size: 1.02em; }
        .math-inline { font-family: 'STIX Two Math', 'Cambria Math', 'Latin Modern Math', \(mono); font-size: .95em; background: \(subtleBg); padding: .08em .32em; border-radius: 4px; }
        .toc { background: \(subtleBg); border: 1px solid \(border); border-radius: 8px; padding: 12px 16px; }
        .toc ul { list-style: none; padding-left: 0; margin: 0; }
        .toc li { margin: .25em 0; }
        .toc .toc-level-1 { padding-left: 1.1em; } .toc .toc-level-2 { padding-left: 2.2em; } .toc .toc-level-3 { padding-left: 3.3em; } .toc .toc-level-4 { padding-left: 4.4em; }
        .footnote-ref a { font-family: \(mono); font-size: .85em; padding: 0 2px; }
        section.footnotes { margin-top: 2.5em; font-size: .88em; color: \(muted); }
        section.footnotes hr { margin-bottom: 1em; }
        section.footnotes ol { padding-left: 1.5em; }
        section.footnotes li { margin-bottom: .45em; }
        .footnote-backref { font-size: .9em; margin-left: 4px; }
        kbd { font-family: \(mono); font-size: .82em; background: \(codeBg); border: 1px solid \(border); border-bottom-width: 2px; border-radius: 5px; padding: .12em .42em; box-shadow: inset 0 -1px 0 \(border); }
        @media print {
          :root { color-scheme: light; }
          html, body { background: #fff !important; }
          body { color: #1f2328; padding: 0; }
          h1, h2, h3, h4, h5, h6, dt { color: #1f2328; }
          h1, h2, hr, th, td, pre, kbd, blockquote, table, details, div.front-matter, .math-block, .toc { border-color: #d0d7de; }
          a { color: #0969da; }
          code, pre, th, div.front-matter, .math-block { background: #f6f8fa; }
          blockquote, h6, .front-matter, section.footnotes { color: #59636e; }
          .code-copy { display: none !important; }
          pre, pre code { white-space: pre-wrap; }
          pre, img, tr, blockquote { break-inside: avoid; }
          \(t.isDark ? "pre code span { color: inherit !important; }" : "")
        }
        ::-webkit-scrollbar { width: 12px; height: 12px; background: transparent; }
        ::-webkit-scrollbar-track, ::-webkit-scrollbar-corner { background: transparent; }
        ::-webkit-scrollbar-thumb { background: transparent; border: 3px solid transparent; border-radius: 6px; background-clip: padding-box; }
        html.scrolling ::-webkit-scrollbar-thumb, ::-webkit-scrollbar-thumb:hover { background-color: \(thumb); }
        ::-webkit-scrollbar-thumb:hover { background-color: \(thumbHover); }
        </style><script nonce="\(nonce)">
        function tovriSetContent(html, base) {
          if (base) document.getElementById('base').href = base;
          const root = document.getElementById('content');
          root.innerHTML = html;
          for (const pre of root.querySelectorAll('pre:not(.front-matter)')) {
            if (!pre.querySelector('code')) continue;
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'code-copy';
            btn.textContent = 'Copy';
            pre.appendChild(btn);
          }
        }
        function tovriScrollToLine(line) {
          const els = document.querySelectorAll('#content > [data-line]');
          let best = null, next = null;
          for (const el of els) { const l = +el.dataset.line; if (l <= line) best = el; else { next = el; break; } }
          if (!best) { window.scrollTo(0, 0); return; }
          let y = best.getBoundingClientRect().top + window.scrollY;
          if (next) {
            const a = +best.dataset.line, b = +next.dataset.line;
            const ny = next.getBoundingClientRect().top + window.scrollY;
            if (b > a) y += (ny - y) * Math.min(1, (line - a) / (b - a));
          }
          window.scrollTo(0, Math.max(0, y - 16));
        }
        let remoteBlocked = false;
        document.addEventListener('securitypolicyviolation', e => {
          if (remoteBlocked || !/^https?:/.test(e.blockedURI)) return;
          remoteBlocked = true;
          window.webkit.messageHandlers.tovri.postMessage({ remoteBlocked: true });
        });
        document.addEventListener('click', e => {
          const copyBtn = e.target.closest && e.target.closest('button.code-copy');
          if (copyBtn) {
            const code = copyBtn.parentElement && copyBtn.parentElement.querySelector('code');
            if (code) {
              const text = code.textContent || '';
              if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).catch(() => {});
              }
              copyBtn.textContent = 'Copied';
              copyBtn.classList.add('copied');
              setTimeout(() => { copyBtn.textContent = 'Copy'; copyBtn.classList.remove('copied'); }, 1400);
            }
            return;
          }
          const a = e.target.closest && e.target.closest('a[href^="#"]');
          if (!a) return;
          e.preventDefault();
          const id = decodeURIComponent(a.getAttribute('href').slice(1));
          const el = document.getElementById(id) || document.getElementsByName(id)[0];
          if (el) el.scrollIntoView({ block: 'start' });
        });
        let frame = 0, hideTimer = 0;
        window.addEventListener('scroll', () => {
          document.documentElement.classList.add('scrolling');
          clearTimeout(hideTimer);
          hideTimer = setTimeout(() => document.documentElement.classList.remove('scrolling'), 900);
          if (frame) return;
          frame = requestAnimationFrame(() => {
            frame = 0;
            let line = 0;
            for (const el of document.querySelectorAll('#content > [data-line]')) {
              line = +el.dataset.line;
              if (el.getBoundingClientRect().bottom > 8) break;
            }
            window.webkit.messageHandlers.tovri.postMessage(line);
          });
        }, { passive: true });
        </script></head><body><div id="content"></div></body></html>
        """
    }
}

/// Breaks the retain cycle between WKUserContentController and the preview view.
private final class PreviewMessageProxy: NSObject, WKScriptMessageHandler {
    var onLine: ((Int) -> Void)?
    var onRemoteContentBlocked: (() -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let n = message.body as? Int { onLine?(n) } else if let d = message.body as? Double { onLine?(Int(d)) }
        else if let d = message.body as? [String: Any], d["remoteBlocked"] as? Bool == true { onRemoteContentBlocked?() }
    }
}

/// Offers to load the remote images a document asked for. It is a native view rather than part
/// of the page because the document's own HTML and CSS could restyle an in-page button to cover
/// the whole preview, so that any click would load them.
private final class RemoteContentBar: NSView {
    static let height: CGFloat = 30
    private let label = NSTextField(labelWithString: "Remote images are blocked to protect your privacy.")
    private let button = NSButton(title: "Load Remote Images", target: nil, action: nil)
    private var theme: Theme?
    var onLoad: (() -> Void)?

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        button.isBordered = false
        button.target = self
        button.action = #selector(load)
        addSubview(label)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ t: Theme) {
        theme = t
        label.textColor = t.chromeSecondary
        button.attributedTitle = NSAttributedString(string: "Load Remote Images", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: t.color(.link) ?? t.accent])
        needsLayout = true
        needsDisplay = true
    }

    @objc private func load() { onLoad?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = theme else { return }
        t.fieldBackground.setFill()
        bounds.fill()
        t.chromeBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let b = button.fittingSize
        let l = label.fittingSize
        let labelWidth = max(0, min(l.width, bounds.width - 16 - 8 - b.width - 12))
        label.frame = NSRect(x: 16, y: floor((bounds.height - l.height) / 2), width: labelWidth, height: l.height)
        button.frame = NSRect(x: label.frame.maxX + 8, y: floor((bounds.height - b.height) / 2), width: b.width, height: b.height)
    }

    override func resetCursorRects() { addCursorRect(button.frame, cursor: .pointingHand) }
}

/// Serves images and media referenced by the previewed document. Other file types are refused,
/// so the page can't read arbitrary files.
private final class PreviewResourceHandler: NSObject, WKURLSchemeHandler {
    private static let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "tif", "tiff", "avif", "heic",
                                               "mp4", "m4v", "mov", "webm", "mp3", "m4a", "wav", "ogg", "oga", "ogv"]
    static let maxSize = 64 * 1024 * 1024
    private var stopped = Set<ObjectIdentifier>()
    private var budget = PreviewResourceBudget()
    private let reads: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    /// A new page starts with the whole budget; WebKit drops the old page's copies.
    func startPage() { budget = PreviewResourceBudget() }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "file" else { fail(task); return }
        let path = url.path
        let ext = (path as NSString).pathExtension.lowercased()
        guard PreviewResourceHandler.allowed.contains(ext) else { fail(task); return }
        let id = ObjectIdentifier(task)
        let budget = self.budget
        reads.addOperation {
            let data = PreviewResourceHandler.read(path, admittedBy: budget, as: PreviewResourceBudget.key(for: url))
            DispatchQueue.main.async {
                guard self.stopped.remove(id) == nil else { return }
                guard let data else { self.fail(task); return }
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    /// The file at `path` if it is a regular file of up to `maxSize` that fits in `budget`.
    static func read(_ path: String, admittedBy budget: PreviewResourceBudget, as key: String) -> Data? {
        // O_NONBLOCK keeps a FIFO from blocking the open. fstat follows symlinks and measures the
        // file actually opened, so a link to a huge or special file is refused as its target.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxSize,
              budget.admit(key, size: Int(info.st_size)) else { return nil }
        let data: Data
        do { data = try file.read(upToCount: maxSize + 1) ?? Data() } catch { return nil }
        return data.count <= maxSize ? data : nil
    }

    private func fail(_ task: WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}

/// Limits how much the preview's page may load from disk in total. WebKit keeps its own copy of
/// every resource, one per URL, so a document listing `big.mp4?1`, `big.mp4?2` and so on would
/// otherwise hold a full copy of the file for each. A URL loaded again, as happens whenever the
/// document is edited, costs nothing more.
final class PreviewResourceBudget {
    static let limit = 256 * 1024 * 1024
    private let lock = NSLock()
    private var admitted: [String: Int] = [:]
    private(set) var total = 0

    /// The URL as WebKit tells resources apart. The fragment is dropped since it never selects
    /// different data; the query is kept because WebKit stores each query as a separate copy.
    static func key(for url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        c.fragment = nil
        return c.string ?? url.absoluteString
    }

    func admit(_ key: String, size: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if admitted[key] != nil { return true }
        guard size <= PreviewResourceBudget.limit - total else { return false }
        admitted[key] = size
        total += size
        return true
    }
}
