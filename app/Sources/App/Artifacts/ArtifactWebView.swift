import QuestmasterCore
import SwiftUI
import WebKit

struct ArtifactWebView: NSViewRepresentable {
    var artifact: ArtifactReference
    var reloadNonce: Int = 0
    var decideNavigation: (URL?, Bool) -> ArtifactNavigationDecision
    var openExternal: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(decideNavigation: decideNavigation, openExternal: openExternal)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            artifact: artifact,
            in: webView,
            reloadNonce: reloadNonce,
            decideNavigation: decideNavigation,
            openExternal: openExternal
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var decideNavigation: (URL?, Bool) -> ArtifactNavigationDecision
        var openExternal: (URL) -> Void
        var loadedPath: String?
        private let watcher = ArtifactFileWatcher()
        private var pendingPath: String?
        private var pendingScrollY: Double?
        private var contentRuleListInstallStarted = false
        private var contentRuleListReady = false
        private var reloadNonce = 0

        init(
            decideNavigation: @escaping (URL?, Bool) -> ArtifactNavigationDecision,
            openExternal: @escaping (URL) -> Void
        ) {
            self.decideNavigation = decideNavigation
            self.openExternal = openExternal
        }

        deinit {
            stop()
        }

        func update(
            artifact: ArtifactReference,
            in webView: WKWebView,
            reloadNonce: Int,
            decideNavigation: @escaping (URL?, Bool) -> ArtifactNavigationDecision,
            openExternal: @escaping (URL) -> Void
        ) {
            self.decideNavigation = decideNavigation
            self.openExternal = openExternal
            pendingPath = artifact.path

            if reloadNonce != self.reloadNonce {
                self.reloadNonce = reloadNonce
                // Manual refresh: reload the current artifact even though its path
                // is unchanged, preserving scroll like the file watcher does.
                if contentRuleListReady, loadedPath == artifact.path {
                    reloadPreservingScroll(in: webView, path: artifact.path)
                    return
                }
                loadedPath = nil
            }

            installNetworkBlockerIfNeeded(on: webView)
        }

        func stop() {
            watcher.stop()
            pendingPath = nil
            loadedPath = nil
            pendingScrollY = nil
        }

        private func installNetworkBlockerIfNeeded(on webView: WKWebView) {
            guard !contentRuleListReady else {
                loadPendingArtifact(in: webView)
                return
            }
            guard !contentRuleListInstallStarted else {
                return
            }

            contentRuleListInstallStarted = true
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: ArtifactWebSecurity.contentRuleIdentifier,
                encodedContentRuleList: ArtifactWebSecurity.remoteBlockRuleList
            ) { [weak self, weak webView] ruleList, error in
                DispatchQueue.main.async {
                    guard let self, let webView else {
                        return
                    }
                    if let ruleList {
                        webView.configuration.userContentController.add(ruleList)
                        self.contentRuleListReady = true
                        self.loadPendingArtifact(in: webView)
                    } else {
                        // The remote blocker is best-effort. Log the failure, allow a
                        // later update() to retry the compile, and still render the
                        // artifact so the pane is not left permanently blank.
                        print("artifact remote blocker compile failed; rendering without it: \(error?.localizedDescription ?? "unknown error")")
                        self.contentRuleListInstallStarted = false
                        self.loadPendingArtifact(in: webView, requireRuleList: false)
                    }
                }
            }
        }

        private func loadPendingArtifact(in webView: WKWebView, requireRuleList: Bool = true) {
            guard !requireRuleList || contentRuleListReady,
                  let path = pendingPath,
                  loadedPath != path else {
                return
            }
            loadArtifact(path: path, in: webView, restoringScrollY: nil)
        }

        private func loadArtifact(path: String, in webView: WKWebView, restoringScrollY scrollY: Double?) {
            loadedPath = path
            pendingScrollY = scrollY
            let url = URL(fileURLWithPath: path)
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            watcher.start(path: path) { [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.loadedPath == path else {
                    return
                }
                self.reloadPreservingScroll(in: webView, path: path)
            }
        }

        private func reloadPreservingScroll(in webView: WKWebView, path: String) {
            webView.evaluateJavaScript("window.scrollY || window.pageYOffset || 0") { [weak self, weak webView] result, _ in
                guard let self,
                      let webView,
                      self.loadedPath == path else {
                    return
                }
                let scrollY = (result as? NSNumber)?.doubleValue ?? 0
                self.loadArtifact(path: path, in: webView, restoringScrollY: scrollY)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let userInitiated = navigationAction.navigationType == .linkActivated
            switch decideNavigation(navigationAction.request.url, userInitiated) {
            case .allowFile:
                decisionHandler(.allow)
            case .openExternal(let url):
                openExternal(url)
                decisionHandler(.cancel)
            case .block:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let scrollY = pendingScrollY else {
                return
            }
            pendingScrollY = nil
            let clampedScrollY = max(0, scrollY)
            guard clampedScrollY.isFinite else {
                return
            }
            webView.evaluateJavaScript("window.scrollTo(0, \(clampedScrollY))") { _, _ in }
        }
    }
}

enum ArtifactWebSecurity {
    static let contentRuleIdentifier = "questmaster-artifact-block-remote-v1"
    // Artifact reports often use CDN-backed presentation libraries. Keep
    // passive external navigations and raw network channels blocked, but allow
    // resources such as scripts, stylesheets, fonts, and images to render.
    static let remoteBlockRuleList = """
    [{
      "trigger": {
        "url-filter": "https?://.*",
        "resource-type": ["raw", "document", "ping"]
      },
      "action": {
        "type": "block"
      }
    }]
    """
}
