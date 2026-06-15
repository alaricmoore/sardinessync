//
//  BioTrackerWebView.swift
//  healthsync
//
//  Created by Alaric Moore on 4/5/26.
//

import SwiftUI
import WebKit

struct BioTrackerWebView: View {
    let baseURL: String
    let path: String
    /// Called when the webview tries to navigate to the native sync bridge URL
    /// (`/ios/sync-healthkit`). Navigation is cancelled and this closure runs instead.
    var onSyncTrigger: (() -> Void)? = nil

    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if let errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Can't reach biotracker")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        self.errorMessage = nil
                        isLoading = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if let url = URL(string: baseURL + path) {
                WebViewRepresentable(
                    url: url,
                    baseHost: URL(string: baseURL)?.host ?? "",
                    onSyncTrigger: onSyncTrigger,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage
                )
                .ignoresSafeArea(edges: .bottom)

                if isLoading {
                    ProgressView("Loading...")
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Server URL not configured")
                        .font(.headline)
                    Text("Tap the gear icon to enter your server address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }
}

// MARK: - WKWebView UIViewRepresentable

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    let baseHost: String
    var onSyncTrigger: (() -> Void)?
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Append a token to the User-Agent so the web app can detect that
        // it's being rendered inside the iOS shell (used to conditionally
        // render the native "Sync" nav entry that hits /ios/sync-healthkit).
        webView.evaluateJavaScript("navigator.userAgent") { ua, _ in
            if let ua = ua as? String {
                webView.customUserAgent = ua + " HealthSynciOS/1.0"
            }
            webView.load(URLRequest(url: self.url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reload if error was cleared (retry tapped)
        if errorMessage == nil && isLoading && webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewRepresentable

        init(_ parent: WebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = "Is Tailscale connected?\n\(error.localizedDescription)"
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Native sync bridge: the web app links to /ios/sync-healthkit in its
            // nav bar; we intercept it, cancel navigation, and run native HealthKit
            // sync instead. The URL never actually hits the server.
            if url.path == "/ios/sync-healthkit" {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onSyncTrigger?()
                }
                decisionHandler(.cancel)
                return
            }

            // Allow navigation within the biotracker domain
            if let host = url.host, host == parent.baseHost {
                decisionHandler(.allow)
                return
            }

            // Allow initial load and same-origin requests
            if navigationAction.targetFrame?.isMainFrame == true && url.host == nil {
                decisionHandler(.allow)
                return
            }

            // External links → open in Safari
            if url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
