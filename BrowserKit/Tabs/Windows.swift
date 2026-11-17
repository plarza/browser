import WebKit

/// What a page asks of the window around it: popups, closing, dialogs, the
/// camera and microphone. The answers come from the shell.
extension Tab: WKUIDelegate {
    private var shell: Shell? { browser?.shell }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A sized window is a popup that expects its opener (sign-in,
        // 3-D Secure); anything else is a new tab, which starts fresh.
        guard windowFeatures.width != nil || windowFeatures.height != nil else {
            if let url = action.request.url { browser?.open(url, from: self) }
            return nil
        }
        let popup = Tab(popupOf: self, configuration: configuration)
        popups.append(popup)
        browser?.adopt(popup, from: self)
        return popup.webView
    }

    public func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    /// Camera and microphone ask every time; the answer is never remembered.
    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let who = origin.port == 0 ? "\(origin.protocol)://\(origin.host)" : "\(origin.protocol)://\(origin.host):\(origin.port)"
        guard let shell else { return .deny }
        return await shell.tab(self, allowCapture: type, for: who) ? .grant : .deny
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await shell?.tab(self, runAlert: message)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await shell?.tab(self, runConfirm: message) ?? false
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await shell?.tab(self, runPrompt: prompt, defaultText: defaultText)
    }

    #if os(macOS)
    // iOS has WebKit's own picker (photos, camera, files) when this isn't implemented.
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await shell?.tab(self, chooseFiles: parameters.allowsMultipleSelection, directories: parameters.allowsDirectories)
    }
    #endif
}
