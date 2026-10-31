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
        config.setURLSchemeHandler(PreviewResourceHandler(), forURLScheme: MarkdownPreviewView.scheme)
        config.userContentController.add(messages, name: "tovri")
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: frame, configuration: config)
        super.init(frame: frame)
        messages.onLine = { [weak self] line in self?.topLine = line }
        messages.onRemoteContent = { [weak self] in self?.onRequestRemoteContent?() }
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tovri")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = showsDivider ? 1 : 0
        webView.frame = NSRect(x: inset, y: 0, width: max(0, bounds.width - inset), height: bounds.height)
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

    private static func shell(theme t: Theme, fontSize: CGFloat, allowRemote: Bool) -> String {
        let remote = allowRemote ? "*" : ""
        let fg = css(t.foreground), muted = css(t.chromeSecondary), accent = css(t.color(.link) ?? t.accent)
        let border = css(t.chromeBorder), codeBg = css(t.fieldBackground), bg = t.translucent ? "transparent" : css(t.background)
        let heading = css(t.foreground), quote = css(t.chromeSecondary)
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
        :root { color-scheme: \(t.isDark ? "dark" : "light"); }
        html, body { background: \(bg); }
        body { margin: 0; padding: 32px 40px 30vh; color: \(fg); font: \(Int(fontSize + 2))px/1.65 -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
               -webkit-font-smoothing: antialiased; word-wrap: break-word; }
        #content { max-width: 880px; margin: 0 auto; }
        h1, h2, h3, h4, h5, h6 { color: \(heading); font-weight: 650; line-height: 1.25; margin: 1.6em 0 0.6em; scroll-margin-top: 16px; }
        h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid \(border); margin-top: .4em; }
        h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid \(border); }
        h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: \(muted); }
        p, ul, ol, blockquote, table, pre, details { margin: 0 0 1em; }
        a { color: \(accent); text-decoration: none; } a:hover { text-decoration: underline; }
        code { font-family: \(mono); font-size: .88em; background: \(codeBg); padding: .15em .4em; border-radius: 5px; }
        pre { background: \(codeBg); border: 1px solid \(border); border-radius: 8px; padding: 14px 16px; overflow-x: auto; line-height: 1.5; }
        pre code { background: none; padding: 0; font-size: .86em; white-space: pre; }
        blockquote { margin-left: 0; padding: .1em 1em; color: \(quote); border-left: 3px solid \(border); }
        blockquote.alert { border-left-color: \(accent); } .alert-title { font-weight: 600; color: \(accent); margin-bottom: .3em; }
        .alert-warning, .alert-caution { border-left-color: \(css(t.color(.deleted) ?? t.accent)); }
        .alert-warning .alert-title, .alert-caution .alert-title { color: \(css(t.color(.deleted) ?? t.accent)); }
        .alert-tip .alert-title { color: \(css(t.color(.inserted) ?? t.accent)); } .alert-tip { border-left-color: \(css(t.color(.inserted) ?? t.accent)); }
        hr { border: 0; border-top: 1px solid \(border); margin: 2em 0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid \(border); padding: 6px 13px; } th { font-weight: 600; background: \(codeBg); }
        img, video { max-width: 100%; } img { border-radius: 6px; }
        img[align=right] { float: right; margin-left: 1em; } img[align=left] { float: left; margin-right: 1em; }
        ul, ol { padding-left: 2em; } li + li { margin-top: .25em; }
        .contains-task-list { list-style: none; padding-left: 1.2em; } .task-list-item input { margin: 0 .45em 0 -1.2em; vertical-align: middle; }
        .front-matter { opacity: .75; }
        kbd { font-family: \(mono); font-size: .8em; border: 1px solid \(border); border-bottom-width: 2px; border-radius: 4px; padding: .1em .4em; }
        mark { background: \(css(t.findMatch)); color: inherit; }
        #remote { display: none; position: sticky; top: 0; z-index: 10; margin: -32px -40px 16px; padding: 8px 40px;
                  font-size: 12px; color: \(muted); background: \(codeBg); border-bottom: 1px solid \(border); }
        #remote.shown { display: block; } #remote a { cursor: pointer; margin-left: .6em; }
        @media print {
          :root { color-scheme: light; }
          html, body { background: #fff !important; }
          body { color: #1f2328; padding: 0; }
          h1, h2, h3, h4, h5, h6 { color: #1f2328; }
          h1, h2, hr, th, td, pre, kbd, blockquote { border-color: #d0d7de; }
          a { color: #0969da; }
          code, pre, th { background: #f6f8fa; }
          blockquote, h6, .front-matter { color: #59636e; }
          pre, pre code { white-space: pre-wrap; }
          pre, img, tr { break-inside: avoid; }
          #remote { display: none !important; }
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
          document.getElementById('content').innerHTML = html;
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
        document.addEventListener('securitypolicyviolation', e => {
          if (/^https?:/.test(e.blockedURI)) document.getElementById('remote').classList.add('shown');
        });
        document.addEventListener('click', e => {
          if (e.target.id !== 'remote-load') return;
          e.preventDefault();
          window.webkit.messageHandlers.tovri.postMessage({ remote: true });
        });
        document.addEventListener('click', e => {
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
        </script></head><body><div id="remote">Remote images are blocked to protect your privacy.<a id="remote-load" href="#">Load Remote Images</a></div><div id="content"></div></body></html>
        """
    }
}

/// Breaks the retain cycle between WKUserContentController and the preview view.
private final class PreviewMessageProxy: NSObject, WKScriptMessageHandler {
    var onLine: ((Int) -> Void)?
    var onRemoteContent: (() -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let n = message.body as? Int { onLine?(n) } else if let d = message.body as? Double { onLine?(Int(d)) }
        else if let d = message.body as? [String: Any], d["remote"] as? Bool == true { onRemoteContent?() }
    }
}

/// Serves images and media referenced by the previewed document. Other file types are refused,
/// so the page can't read arbitrary files.
private final class PreviewResourceHandler: NSObject, WKURLSchemeHandler {
    private static let allowed: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "tif", "tiff", "avif", "heic",
                                               "mp4", "m4v", "mov", "webm", "mp3", "m4a", "wav", "ogg", "oga", "ogv"]
    private static let maxSize = 64 * 1024 * 1024
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "file" else { fail(task); return }
        let path = url.path
        let ext = (path as NSString).pathExtension.lowercased()
        guard PreviewResourceHandler.allowed.contains(ext) else { fail(task); return }
        let id = ObjectIdentifier(task)
        DispatchQueue.global(qos: .userInitiated).async {
            // stat follows symlinks, so a link to a huge or special file is measured as its target.
            var info = stat()
            let isSmallFile = stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size <= PreviewResourceHandler.maxSize
            let data = isSmallFile ? FileManager.default.contents(atPath: path) : nil
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

    private func fail(_ task: WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}
