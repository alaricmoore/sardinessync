# SardinesSync Testing Guide

## Pre-testing setup

1. **Xcode project configuration**
   - [ ] Info.plist has `BGTaskSchedulerPermittedIdentifiers` array
   - [ ] Info.plist has `NSHealthShareUsageDescription`
   - [ ] Signing & Capabilities → HealthKit enabled
   - [ ] Signing & Capabilities → Background Modes includes "Background processing"
   - [ ] `healthsync.entitlements` includes:
     - `com.apple.developer.healthkit`
     - `com.apple.developer.healthkit.background-delivery`

2. **Server**
   - [ ] `/api/flare-status` responds correctly:
     - `curl -H "Authorization: Bearer YOUR_TOKEN" "https://<YOUR_SERVER>/api/flare-status?user_id=1"`

3. **Device**
   - [ ] Install on iPhone via Xcode
   - [ ] Tailscale connected
   - [ ] iOS Settings → Notifications → healthsync → Notifications enabled

---

## Feature testing

### 1. HealthKit authorization
- [ ] Launch app, Sync tab
- [ ] Tap "Authorize HealthKit"
- [ ] Permission sheet appears
- [ ] Grant all requested permissions
- [ ] "HealthKit authorized" message appears

### 2. Manual sync
- [ ] Server URL: `https://<YOUR_SERVER>/api/health-sync`
- [ ] API Token: from Flask config
- [ ] User ID: `1`
- [ ] Tap "Sync Health Data"
- [ ] "syncing..." state with progress indicator
- [ ] Wait for completion
- [ ] "synced X fields: steps, hrv, ..." appears
- [ ] Flask server logs show successful POST
- [ ] Data appears in biotracker web UI

### 3. WKWebView integration
- [ ] Log tab shows loading indicator
- [ ] Biotracker log page loads
- [ ] Data entry in the web form works
- [ ] Risk tab loads forecast/status page
- [ ] Navigation between web pages works
- [ ] Disconnect Tailscale; error message: "Can't reach biotracker — Is Tailscale connected?"
- [ ] "Retry" button works after reconnecting Tailscale

### 4. Notification settings
- [ ] Sync tab → Notifications section
- [ ] "Enable Notifications" toggle on
- [ ] System permission prompt appears (first time only)
- [ ] Bedtime Reminder hour can be changed
- [ ] Auto-Sync Target hour can be changed
- [ ] Trend Alert Threshold can be set (e.g. 3.0)

### 5. Bedtime notification (quick test)
Schedule a notification 10 seconds out by adding a debug button to `SyncSettingsView`:

```swift
Button("Test Bedtime Notification (10s)") {
    let content = UNMutableNotificationContent()
    content.title = "Time to log"
    content.body = "How was today?"
    content.sound = .default
    content.categoryIdentifier = NotificationManager.bedtimeLogCategory

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
    let request = UNNotificationRequest(identifier: "test_bedtime", content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(request)
}
```

- [ ] Tap test button
- [ ] Wait 10 seconds
- [ ] Notification appears
- [ ] Tap notification, app opens to Log tab
- [ ] Remove debug button after testing

### 6. Background sync (Xcode simulator)

1. Run app on device from Xcode
2. Settings configured (server URL, token, etc.)
3. In Xcode → Debug → Pause execution (or just let it run)
4. Xcode console (Cmd+Shift+Y), paste:
   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.biotracking.healthsync.daily"]
   ```
5. Resume execution
6. Watch console for:
   - "Starting background sync..."
   - HealthKit queries
   - Network requests
   - "Background sync completed"
7. Verify:
   - [ ] `lastSyncTimestamp` updated in app UI
   - [ ] Data synced to server
   - [ ] Flare status fetched
   - [ ] Notifications scheduled (Notification Center → Scheduled)

### 7. Flare alerts (mock data)

Two ways to trigger:

Option A: temporarily edit `/api/flare-status` to return `predicted_flare: true` and `score_delta: 4.0`, then trigger a background sync. Both threshold and trend alerts should fire.

Option B: add a debug button to force-fetch:

```swift
Button("Test Flare Check") {
    FlareChecker.shared.fetchStatus(
        serverURL: serverURL,
        apiToken: apiToken,
        userID: userID
    ) { status in
        if let status = status, status.ok,
           let eval = FlareChecker.shared.evaluate(status: status, trendThreshold: 3.0) {
            if eval.thresholdCrossed {
                NotificationManager.shared.scheduleFlareThresholdAlert(
                    score: eval.score,
                    maxScore: eval.maxScore
                )
            }
            if eval.trendAlert {
                NotificationManager.shared.scheduleFlareTrendAlert(delta: eval.scoreDelta)
            }
        }
    }
}
```

- [ ] Trigger flare check
- [ ] Threshold alert fires when `predicted_flare == true`
- [ ] Trend alert fires when delta >= threshold
- [ ] Tap alerts, observe app behavior
- [ ] De-duplication holds (no re-alert same day)

### 8. Med dose reminders

Requires Flask dose schedule support:

- [ ] Add doses for tomorrow in Flask
- [ ] Trigger background sync (simulates evening sync)
- [ ] iOS Settings → Notifications → Scheduled
- [ ] Dose reminders scheduled for tomorrow at correct times
- [ ] Let one fire (or simulate the time)
- [ ] Tapping notification opens to Log tab

### 9. Shortcuts integration

- [ ] iOS Shortcuts app → new shortcut
- [ ] Search "Open Biotracker Log", add action, save
- [ ] Run shortcut, app opens to Log tab

- [ ] Another shortcut, search "Sync Biotracker", add action, save
- [ ] Run shortcut, sync completes, return message visible

- [ ] Optional: automation (Settings → Automation)
  - Trigger: Time of Day (9:00 PM)
  - Action: run "Open Biotracker Log"
  - Test at 9 PM

### 10. Historical backfill
- [ ] Sync tab → Historical Data section
- [ ] Pick a preset (e.g. "Week" = 7 days)
- [ ] "Start Backfill"
- [ ] Progress bar appears
- [ ] Status updates: "Processing 2026-04-04 (1/7)..."
- [ ] Completes with "Synced X days, skipped Y (no data)"
- [ ] Server confirms historical data populated

---

## Production testing

After Xcode testing passes:

1. **Real-world background sync**
   - [ ] Set `syncHour` to current time + 1 hour
   - [ ] Close app completely (swipe up from app switcher)
   - [ ] Wait until target hour
   - [ ] Re-open app ~5–15 minutes after target hour
   - [ ] Check "Last auto-sync" timestamp
   - [ ] Verify data synced

2. **Multi-day usage**
   - [ ] Use the app naturally for 3–5 days
   - [ ] Monitor notification delivery
   - [ ] Check sync reliability
   - [ ] Review battery impact (Settings → Battery)

3. **Error handling**
   - [ ] Disconnect Tailscale, verify graceful degradation
   - [ ] Invalid API token, verify clear error message
   - [ ] Airplane mode, verify no crashes

---

## Troubleshooting

### Background sync not firing
- Settings → General → Background App Refresh → healthsync must be on
- Device must have power (iOS throttles background tasks on low battery)
- Device must not be in Low Power Mode
- Plug in device overnight (iOS prioritizes background tasks while charging)

### Notifications not appearing
- Settings → Notifications → healthsync → Allow Notifications must be on
- Settings → Screen Time → Content & Privacy Restrictions → Allowed Apps → healthsync (if Screen Time is in use)
- Do Not Disturb / Focus mode

### HealthKit data not syncing
- iPhone has HealthKit data (Health app → Browse)
- HealthKit permissions granted (Health app → Sharing → Apps → healthsync)
- Re-authorize from inside the app

### Web views not loading
- Tailscale connection is up (Tailscale app → green)
- Server URL has no typos and starts with `https://`
- Flask server is running
- Open `https://<YOUR_SERVER>` in Safari first

---

## Completion criteria

The app is ready for production when:

- [ ] All manual tests pass
- [ ] Background sync has worked at least once
- [ ] Notifications deliver reliably
- [ ] No crashes in 3 days of testing
- [ ] Battery usage under 5% per day
- [ ] Web views load consistently on Tailscale
- [ ] Shortcuts execute successfully

---

**Note on background tasks:** iOS does not guarantee a specific execution time for background tasks. Apple's scheduler decides when to run them based on device usage patterns, battery level, and other factors. The app requests a target hour, but iOS may run earlier or later — typically within 1–4 hours of the requested time.
