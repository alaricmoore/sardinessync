//
//  ContentView.swift
//  healthsync
//
//  Created by Alaric Moore on 3/29/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var syncer = HealthSyncer()

    @AppStorage("serverURL") private var serverURL = "https://<YOUR_SERVER>/api/health-sync"
    @AppStorage("apiToken") private var apiToken = ""
    @AppStorage("userID") private var userID = 1

    @State private var showSettings = false

    var body: some View {
        BioTrackerWebView(
            baseURL: baseURL,
            path: "/",
            onSyncTrigger: {
                syncer.syncNow(serverURL: serverURL, apiToken: apiToken, userID: userID)
            }
        )
        .overlay(alignment: .topTrailing) {
            // .overlay + explicit frame ensures SwiftUI routes touches
            // over the WKWebView to this button. 44x44 is the Apple HIG
            // minimum hit area so taps land reliably on a phone screen.
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.black.opacity(0.55)))
            }
            .contentShape(Circle())
            .padding(.top, 4)
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SyncSettingsView(syncer: syncer, serverURL: $serverURL, apiToken: $apiToken, userID: $userID)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLogTab)) { _ in
            // Log tab no longer exists; the web view owns navigation.
            // Just make sure the settings sheet is dismissed so any deep-link
            // lands on the web app.
            showSettings = false
        }
    }

    /// Derive base URL from the stored health-sync endpoint
    private var baseURL: String {
        serverURL.replacingOccurrences(of: "/api/health-sync", with: "")
    }
}

#Preview {
    ContentView()
}
