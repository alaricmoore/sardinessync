//
//  BLEWearableSyncView.swift
//  healthsync
//
//  Foreground BLE sync UI for the UV wearable.
//
//  Flow from the user's side: hold the wearable button 1.5s to put it into
//  the ~10s advertising window, then tap "Sync wearable" here. The view
//  shows scan / connect / chunk progress.
//

import SwiftUI

struct BLEWearableSyncView: View {
    @StateObject private var syncer = BLEWearableSyncer()

    // serverURL is shared with the HealthKit sync; we derive the wearable
    // ingest URL from the same base. apiToken (HealthKit) is intentionally
    // NOT reused — the firmware uses a separate wearable_token per its
    // comment in uv_wearable.ino. Stored in Keychain rather than @AppStorage.
    @AppStorage("serverURL") private var serverURL = "https://app.sardinetracker.com/api/health-sync"

    @State private var wearableToken: String = ""
    @State private var error: String?

    private var baseURL: String {
        serverURL.replacingOccurrences(of: "/api/health-sync", with: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Wearable Token") {
                    SecureField("Bearer token", text: $wearableToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: wearableToken) { _, new in
                            // Save on every edit so the user doesn't need a
                            // separate "save" tap. Empty string deletes.
                            if new.isEmpty {
                                Keychain.delete(key: Keychain.wearableTokenKey)
                            } else {
                                Keychain.save(new, for: Keychain.wearableTokenKey)
                            }
                        }
                    Text("Separate from the HealthKit API token. Set wearable_token on the Pi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(action: startSync) {
                        HStack(spacing: 16) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.title2)
                                .foregroundStyle(.blue)
                                .frame(width: 40)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(syncer.isSyncing ? "Syncing wearable..." : "Sync wearable")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("Hold the wearable button for 1.5s first")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if syncer.isSyncing { ProgressView() }
                        }
                        .padding(.vertical, 8)
                    }
                    .disabled(syncer.isSyncing || wearableToken.isEmpty)
                }

                if syncer.isSyncing || !syncer.statusMessage.isEmpty {
                    Section("Status") {
                        if let name = syncer.deviceName {
                            LabeledContent("Device", value: name)
                        }
                        Text(syncer.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if syncer.bytesPending > 0 {
                            ProgressView(
                                value: Double(syncer.bytesUploaded),
                                total: Double(max(syncer.bytesPending, 1))
                            )
                        }
                    }
                }

                if !syncer.lastResult.isEmpty {
                    Section("Last Result") {
                        Text(syncer.lastResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = error {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Wearable")
            .onAppear {
                if wearableToken.isEmpty {
                    wearableToken = Keychain.load(key: Keychain.wearableTokenKey) ?? ""
                }
            }
        }
    }

    private func startSync() {
        error = nil
        Task {
            do {
                _ = try await syncer.sync(baseURL: baseURL, bearerToken: wearableToken)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

#Preview {
    BLEWearableSyncView()
}
