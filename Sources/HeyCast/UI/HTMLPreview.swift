import SwiftUI
import WebKit

/// Renders an HTML string in a themed WKWebView. JavaScript is disabled (the
/// content is untrusted), links open in the system browser instead of
/// navigating inside the pane, and injected CSS matches the launcher theme.
///
/// The web view scrolls its own content — don't wrap it in a ScrollView
/// (AppKit views embedded in SwiftUI scroll views lose their content).
struct HTMLPreview: NSViewRepresentable {
    let html: String
    let theme: Theme
    /// Resolves relative URLs in the content.
    var baseURL: URL? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastKey: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // target=_blank links (and window.open, were JS on) open externally.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = false  // untrusted content
        configuration.defaultWebpagePreferences = pagePreferences
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")  // show the panel through
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let key = "\(html.count)-\(html.hashValue)-\(themeKey)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        webView.loadHTMLString(Self.wrapped(html, theme: theme), baseURL: baseURL)
    }

    private var themeKey: String { "\(theme.isDark)-\(theme.textColor.description)" }

    static func wrapped(_ bodyHTML: String, theme: Theme) -> String {
        let textHex = NSColor(theme.textColor).cssHex
        let mutedHex = NSColor(theme.textColor).withAlphaComponent(0.62).cssHex
        let borderHex = NSColor(theme.textColor).withAlphaComponent(0.18).cssHex
        let linkColor = theme.isDark ? "#6cb2f5" : "#0a66c2"
        let codeBackground = theme.isDark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)"
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: \(theme.isDark ? "dark" : "light"); }
          body { margin: 0; padding: 10px 18px 18px; background: transparent; color: \(textHex);
                 font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                 font-size: 13px; line-height: 1.55; word-wrap: break-word;
                 -webkit-font-smoothing: antialiased; }
          p { margin: 0 0 10px; }
          h1, h2, h3, h4 { font-size: 14px; margin: 14px 0 6px; }
          img { max-width: 100%; height: auto; border-radius: 8px; margin: 6px 0; }
          a { color: \(linkColor); text-decoration: none; }
          blockquote { margin: 8px 0; padding: 2px 0 2px 12px;
                       border-left: 3px solid \(borderHex); color: \(mutedHex); }
          pre { background: \(codeBackground); border-radius: 6px; padding: 8px 10px;
                overflow-x: auto; font-size: 12px; }
          code { font-family: ui-monospace, Menlo, monospace; font-size: 12px;
                 background: \(codeBackground); border-radius: 4px; padding: 1px 4px; }
          pre code { background: transparent; padding: 0; }
          ul, ol { margin: 0 0 10px; padding-left: 22px; }
          li { margin-bottom: 4px; }
          hr { border: 0; border-top: 1px solid \(borderHex); margin: 12px 0; }
          iframe { max-width: 100%; border: 0; border-radius: 8px; }
          ::-webkit-scrollbar { width: 0; height: 0; }
        </style></head><body>\(bodyHTML)</body></html>
        """
    }
}

private extension NSColor {
    var cssHex: String {
        guard let c = usingColorSpace(.sRGB) else { return "#888888" }
        return String(format: "#%02x%02x%02x",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
