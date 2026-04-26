# SardinesSync Implementation Status

**Last updated:** 2026-04-05

## Complete

### Flask backend
- `/api/flare-status` endpoint implemented and deployed to `https://<YOUR_SERVER>`
- Returns `score`, `predicted_flare`, `score_delta`, `doses_due`
- Bearer token authentication
- Tested with curl

### iOS app (Swift)
- All 9 source files implemented
- TabView with Sync, Log, Risk tabs
- WKWebView integration for the mobile pages
- HealthKit queries and sync logic
- BGTaskScheduler background task
- NotificationManager (4 notification types)
- FlareChecker (API client and alert evaluation)
- iOS Shortcuts integration
- Domain configured to `https://<YOUR_SERVER>`

### Documentation
- `ARCHITECTURE.md` — system overview
- `XCODE_SETUP.md` — project configuration
- `TESTING_GUIDE.md` — test procedures
- `README.md` — quick start
- `NOTIFICATIONS.md` — notification reference

---

## Remaining: Xcode configuration

Full checklist in `XCODE_SETUP.md`. Critical items below.

### Info.plist keys
- `BGTaskSchedulerPermittedIdentifiers` (Array)
  - Item 0: `com.biotracking.healthsync.daily`
- `NSHealthShareUsageDescription` (String)
  - "Biotracker needs access to your health data to sync steps, heart rate, HRV, sleep temperature, and sun exposure to your personal health tracker."

### Signing & Capabilities
- HealthKit, with Background Delivery on
- Background Modes, "Background processing" only

### Entitlements
`healthsync.entitlements` should contain:
- `com.apple.developer.healthkit` = true
- `com.apple.developer.healthkit.background-delivery` = true

### Adding Info.plist keys in Xcode
1. Select the project in the navigator
2. Select the healthsync target
3. Open the Info tab
4. Hover an existing key, click "+"
5. Type `BGTaskSchedulerPermittedIdentifiers`
6. Set type Array, expand, click "+" to add Item 0 as String
7. Set Item 0 value to `com.biotracking.healthsync.daily`
8. Repeat for `NSHealthShareUsageDescription` (String)

---

## First test run

After Xcode configuration:

1. Connect a real iPhone — HealthKit doesn't work in the Simulator
2. Select iPhone as target in the Xcode toolbar
3. Cmd+R to build and run
4. In the app:
   - Tap "Authorize HealthKit", grant all permissions
   - Server URL: `https://<YOUR_SERVER>/api/health-sync`
   - API Token: from Flask config
   - User ID: `1`
   - Tap "Sync Health Data"
5. Confirm:
   - Status line "synced 9 fields: steps, hrv, ..."
   - Flask logs show the POST
   - Log tab loads the log page
   - Risk tab loads the forecast page

If the first sync fails:

| Problem | Fix |
|---------|-----|
| HealthKit not authorized | Use a real iPhone, not the Simulator |
| Sync fails with network error | Tailscale disconnected on iPhone |
| Web views blank | Tailscale, plus confirm Flask is running |
| Build errors about capabilities | Re-check Signing & Capabilities tab |

---

## Full testing checklist

Once first sync works, see `TESTING_GUIDE.md`.

### Quick (~30 min)
- [ ] Manual sync (covered above)
- [ ] Log tab navigation
- [ ] Risk tab navigation
- [ ] Notification permission request
- [ ] Settings persistence (close and reopen)
- [ ] Historical backfill (7-day preset)

### Advanced (~30–60 min)
- [ ] Background sync (Xcode debug command)
- [ ] Flare alerts (server returning `predicted_flare: true`)
- [ ] Med dose reminders (`doses_due` populated)
- [ ] Shortcuts integration

---

## Xcode debugging tips

### View console
- Run from Xcode, then Cmd+Shift+Y
- Watch for HealthKit query results, network responses, error messages

### Force background task
Pause the debugger and run in the console:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.biotracking.healthsync.daily"]
```

### Check scheduled notifications
Add a temporary debug button to `SyncSettingsView`:

```swift
Button("Show Scheduled Notifications") {
    UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
        print("Scheduled notifications (\(requests.count)):")
        for req in requests {
            print("  \(req.identifier): \(req.content.title)")
        }
    }
}
```

---

## Success criteria

The app is working correctly when:

- Manual sync completes
- Web views load the biotracker pages
- Notification permission is granted
- No crashes during normal use
- HealthKit data appears in the Flask database
- Background sync runs (verify via the "Last auto-sync" timestamp)
- Shortcuts appear in the Shortcuts app

---

## Implementation vs original spec

| Spec | Implementation | Notes |
|------|----------------|-------|
| Server: <YOUR_SERVER> | <YOUR_SERVER> | Updated throughout |
| Tailscale-only access | DuckDNS domain | Still requires auth |
| `/api/flare-status` endpoint | Implemented | Deployed and tested |
| 4 notification types | All implemented | |
| BGTaskScheduler | Implemented | Needs Xcode config |
| iOS Shortcuts | 2 intents | Available after first run |

No features cut.

---

## After first successful sync

1. Background sync starts running. iOS learns usage patterns and runs the task around the configured hour (default 8 PM). Verify via the "Last auto-sync" timestamp.
2. Notifications get scheduled — bedtime reminder at 9 PM daily, flare alerts when conditions met, med reminders if `doses_due` is populated.
3. Shortcuts become available. In the Shortcuts app, search for "biotracker" or "healthsync". Wire into automations (e.g. "9 PM → Open Biotracker Log").
4. Daily use: Log tab for entries, Risk tab for forecast, manual sync for immediate updates, backfill for historical data.

---

## Common Xcode setup gotchas

- Info.plist keys are case-sensitive and must be typed exactly
- Background Modes: check "Background processing", not "Background fetch"
- HealthKit Background Delivery is a separate checkbox in the capability
- Entitlements file should auto-update when capabilities are added
