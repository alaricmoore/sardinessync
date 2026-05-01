# SardinesSync Architecture

**Version:** 1.0
**Date:** 2026-04-05
**Platform:** iOS 17+, Swift 5
**Authors:** Alaric Moore, with Aplaude (Claude Opus)

## Overview

SardinesSync is the iOS companion to the Flask-based biotracker server. It provides:

- Automatic daily sync of HealthKit data (steps, HRV, heart rate, sleep temp, UV exposure, etc.)
- Embedded web views for the biotracker mobile pages (log, forecast)
- Local notifications for medication reminders, bedtime logging, and flare risk alerts
- iOS Shortcuts integration for automation and Siri

Design principles: background delivery, privacy-first (no third-party network destinations), HealthKit-native.

---

## Architecture diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     iOS healthsync App                      │
│                                                             │
│  ┌───────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │  Sync Tab     │  │   Log Tab    │  │   Risk Tab      │  │
│  │               │  │              │  │                 │  │
│  │ Settings      │  │  WKWebView   │  │   WKWebView     │  │
│  │ Manual Sync   │  │  /mobile/log │  │  /mobile/status │  │
│  │ Backfill      │  │              │  │                 │  │
│  └───────┬───────┘  └──────┬───────┘  └────────┬────────┘  │
│          │                 │                   │           │
│          └─────────────────┴───────────────────┘           │
│                            │                               │
│         ┌──────────────────┴──────────────────┐            │
│         │       HealthSyncer (Core Logic)     │            │
│         │  - Query HealthKit data             │            │
│         │  - Compute RMSSD from RR intervals  │            │
│         │  - POST to /api/health-sync         │            │
│         │  - Backfill historical data         │            │
│         └──────────────────┬──────────────────┘            │
│                            │                               │
│    ┌───────────────────────┴────────────────────────────┐  │
│    │        BackgroundSyncTask (Automation)             │  │
│    │  - Triggered daily via BGTaskScheduler            │  │
│    │  - Calls HealthSyncer.syncNowSilent()             │  │
│    │  - Fetches FlareChecker.fetchStatus()             │  │
│    │  - Schedules notifications via NotificationMgr    │  │
│    └───────────────────────┬────────────────────────────┘  │
│                            │                               │
│    ┌───────────────────────┼────────────────────────────┐  │
│    │         FlareChecker  │  NotificationManager        │  │
│    │  - GET /api/flare-   │  - Bedtime log reminder     │  │
│    │    status             │  - Med dose reminders       │  │
│    │  - Evaluate alerts    │  - Flare threshold alert    │  │
│    │  - Return structured  │  - Flare trend alert        │  │
│    │    data               │  - Deep linking to tabs     │  │
│    └───────────────────────┴────────────────────────────┘  │
│                                                             │
│    ┌─────────────────────────────────────────────────────┐ │
│    │           iOS Shortcuts (AppIntents)                 │ │
│    │  - "Open Biotracker Log" → deep link to Log tab     │ │
│    │  - "Sync Biotracker" → trigger manual sync          │ │
│    └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ HTTPS (Bearer token auth)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Flask Biotracker Server                        │
│              (https://<YOUR_SERVER>)                 │
│                                                             │
│  ┌──────────────────┐   ┌────────────────────────────────┐ │
│  │ /api/health-sync │   │  /api/flare-status             │ │
│  │ - Receives       │   │  - Current flare score         │ │
│  │   HealthKit data │   │  - Predicted flare bool        │ │
│  │ - Stores in DB   │   │  - Score delta (trend)         │ │
│  │                  │   │  - Doses due today             │ │
│  └──────────────────┘   └────────────────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │            Mobile Web Pages                          │  │
│  │  - /mobile/log   → embedded in iOS Log tab          │  │
│  │  - /mobile/status → embedded in iOS Risk tab        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Data flow

### 1. Manual sync

```
User taps "Sync Health Data"
  ↓
ContentView → HealthSyncer.syncNow()
  ↓
HealthSyncer queries HealthKit for today:
  - Steps (sum)
  - HRV SDNN (average)
  - Resting heart rate (average)
  - SpO2 (most recent)
  - Respiratory rate (most recent)
  - Time in daylight (sum)
  - Wrist temperature (average)
  - Body temperature (most recent)
  - RMSSD (computed from overnight RR intervals)
  ↓
HealthSyncer.postToServer()
  ↓
POST /api/health-sync with Bearer token
  {
    "user_id": 1,
    "date": "2026-04-05",
    "steps": 8432,
    "hrv": 45.2,
    ...
  }
  ↓
Flask receives, validates, stores in HealthData table
  ↓
Response: {"ok": true, "fields_updated": [...]}
  ↓
HealthSyncer updates @Published lastResult
  ↓
UI shows "synced 9 fields: steps, hrv, ..."
```

### 2. Automatic evening sync (background)

```
iOS triggers BGAppRefreshTask at ~8 PM
  ↓
BackgroundSyncTask.handle()
  ↓
Step 1: HealthSyncer.syncNowSilent()
  - Same HealthKit queries as manual sync
  - Silent (no UI updates)
  - Callback on completion
  ↓
Step 2: FlareChecker.fetchStatus()
  - GET /api/flare-status?user_id=1
  - Returns: score, predicted_flare, score_delta, doses_due
  ↓
Step 3: Evaluate alert conditions
  - If predicted_flare == true → threshold alert
  - If score_delta >= 3.0 → trend alert
  ↓
Step 4: NotificationManager schedules notifications
  - Flare alerts (immediate)
  - Med dose reminders for tomorrow
  - Bedtime log reminder (daily repeating)
  ↓
Step 5: Update lastSyncTimestamp in UserDefaults
  ↓
Step 6: task.setTaskCompleted(success: true)
  ↓
Step 7: BackgroundSyncTask.scheduleNextSync()
  - Queues next day's background task
```

### 3. Notification delivery to user action

```
iOS delivers notification at scheduled time
  ↓
User taps notification
  ↓
NotificationManager.userNotificationCenter(didReceive:)
  ↓
If category == BEDTIME_LOG or MED_DOSE:
  Post Notification.Name.openLogTab
  ↓
ContentView receives notification
  ↓
Sets selectedTab = 1 (Log tab)
  ↓
App opens with Log web view visible
```

---

## Components

### HealthSyncer.swift
HealthKit integration and network sync.

Responsibilities:
- Request HealthKit authorization for all needed data types
- Query HealthKit using sum, average, and most-recent helpers
- Compute RMSSD from heartbeat series (RR intervals during sleep)
- Format data as JSON payload
- POST to `/api/health-sync` with Bearer token authentication
- Backfill historical data, day-by-day in reverse chronological order
- Provide both UI-updating (`syncNow()`) and silent (`syncNowSilent()`) variants

Key methods:
- `requestAuthorization()` — one-time HealthKit permission request
- `syncNow()` — interactive sync with UI feedback
- `syncNowSilent()` — background sync with completion callback
- `backfillHealthData()` — batch sync for historical days
- Query helpers: `querySum()`, `queryAverage()`, `queryMostRecent()`, `queryRMSSD()`

### BackgroundSyncTask.swift
Automated daily sync via BGTaskScheduler.

Responsibilities:
- Register `com.biotracking.healthsync.daily` task with iOS
- Schedule next execution around target hour (default 8 PM)
- Execute the sync → flare check → notification scheduling pipeline
- Handle task expiration gracefully
- Update last sync timestamp

Key methods:
- `register()` — called once at app init
- `scheduleNextSync()` — queues next day's task
- `handle(task:)` — executes the background workflow

iOS controls actual execution time. The app *requests* 8 PM, but the system may run earlier or later based on its own heuristics.

### FlareChecker.swift
Fetch flare risk data from the Flask API.

Responsibilities:
- GET `/api/flare-status` with Bearer token
- Decode JSON response into Swift structs
- Evaluate alert conditions (threshold crossed, rapid trend)
- Return structured data for notification scheduling

Data models:
- `FlareStatus` — decoded API response
- `FlareStatusFactor` — individual risk factors (UV, symptoms, etc.)
- `DoseReminder` — medication doses due
- `AlertEvaluation` — processed alert decision

Key methods:
- `fetchStatus()` — async network call
- `evaluate()` — alert-trigger logic

### NotificationManager.swift
Local notification handling.

Responsibilities:
- Request notification permissions
- Register categories (BEDTIME_LOG, MED_DOSE, FLARE_THRESHOLD, FLARE_TREND)
- Schedule notifications with appropriate triggers
- Handle notification taps (deep linking)
- De-duplicate alerts (don't re-alert same day)
- Present notifications even when the app is in foreground

Notification types:
1. Bedtime log reminder — daily repeating at configured hour
2. Med dose reminders — scheduled per `/api/flare-status` response
3. Flare threshold alert — when `predicted_flare == true`
4. Flare trend alert — when `score_delta` exceeds threshold

Key methods:
- `setup()` — register categories, set delegate
- `requestAuthorization()` — iOS permission prompt
- `scheduleBedtimeReminder()` — UNCalendarNotificationTrigger (repeating)
- `scheduleDoseReminders()` — batch schedule tomorrow's doses
- `scheduleFlareThresholdAlert()` — immediate trigger with de-dupe
- `scheduleFlareTrendAlert()` — immediate trigger with de-dupe

### BioTrackerWebView.swift
Embed Flask mobile pages in native UI.

Responsibilities:
- Wrap WKWebView in a SwiftUI view
- Handle loading states and errors
- Persist cookies for authentication
- Prevent external navigation (open in Safari instead)
- Show user-friendly error when Tailscale is unreachable

Features:
- Loading indicator during page load
- Retry button on network failure
- Gestural back/forward navigation
- Domain-scoped navigation (stays within the biotracker host)

### SyncSettingsView.swift
Settings and sync controls.

Responsibilities:
- Display server configuration (URL, token, user ID)
- Manual sync button with visual feedback
- HealthKit authorization trigger
- Notification settings (enable/disable, timing, thresholds)
- Historical backfill with progress tracking
- Display last sync timestamp

`@AppStorage` keys:
- `serverURL` — Flask endpoint
- `apiToken` — Bearer token
- `userID` — numeric user ID
- `notificationsEnabled` — master toggle
- `bedtimeReminderHour` — notification time
- `syncHour` — background task target time
- `flareScoreTrendThreshold` — delta for trend alerts
- `lastSyncTimestamp` — last successful sync ISO date

### ShortcutIntents.swift
iOS Shortcuts integration.

Responsibilities:
- Expose app actions to the Shortcuts app
- Handle deep linking from Shortcuts
- Execute background sync via Shortcuts/Siri

Actions:
1. Open Biotracker Log — posts notification to switch to Log tab
2. Sync Biotracker — executes `syncNowSilent()`, returns success message

Usage:
- Add to Shortcuts app for manual triggers
- Use in iOS Automations (e.g. "every day at 9 PM → Open Biotracker Log")
- Invoke via Siri ("Hey Siri, sync biotracker")

---

## Security and privacy

### HealthKit data
- Never leaves the device unencrypted; transmitted over HTTPS only
- User controls permissions via the Health app and can revoke any time
- No HealthKit data stored locally — queried on demand, sent to server, discarded
- Background delivery respects revocation; sync fails gracefully when access is removed

### Network authentication
- Bearer token stored via `@AppStorage` (Keychain-backed)
- HTTPS only
- No hardcoded credentials; user configures token manually

### Notification privacy
- All processing on-device
- No remote notifications (APNs); no third-party servers
- User controls per-category permissions in iOS Settings

### Web view isolation
- Default WKWebView data store — persistent cookies, but isolated from Safari
- No JavaScript injection
- Domain-scoped navigation; external links open in Safari

---

## Performance

### HealthKit query optimization
- Predicate-based queries fetch only the requested date range
- HKStatisticsQuery for sums and averages
- Async execution with completion callbacks
- 0.5s delay between days during backfill to avoid server overload

### Background task efficiency
- Queries plus network typically complete in under 30 seconds
- Aborts gracefully on iOS task expiration
- iOS throttles background tasks on low battery automatically

### Network resilience
- 15-second timeout on API requests
- Failed sync doesn't crash; retries on the next cycle
- Offline degradation: web views show error, notifications don't fire

---

## Possible future additions

Out of scope for v1.0:

- Widget showing today's flare score on the home screen
- Watch app for quick log entry and step count
- HealthKit write-back of corrected data from the server
- APNs integration for server-initiated push (requires server changes)
- Local caching of last flare status for offline viewing
- Native Swift Charts views for historical trends
- Siri suggestions based on usage patterns

---

## Maintenance

### Common issues

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Background sync never runs | Low battery / Low Power Mode | Charge device, disable LPM |
| Notifications don't fire | Permissions denied | Settings → Notifications |
| HealthKit data missing | Permissions not granted | Health app → Sharing → healthsync |
| Web views blank | Tailscale disconnected | Reconnect Tailscale |
| Sync fails with 401 | Invalid API token | Re-enter token in settings |

### Debugging tools
- Xcode Console for HealthKit query results and network responses
- BGTaskScheduler `_simulateLaunchForTaskWithIdentifier:` to force a run
- Notification Inspector in iOS Settings
- Charles Proxy for network traffic (HTTPS decryption)

### Logging
- Print statements at sync start/end and notification scheduling
- Log API responses (status code, body)
- Track background task execution start time and completion status

For production, consider OSLog for persistent logging without performance penalty.

---

## Dependencies

### Apple frameworks
- HealthKit — health data access
- BackgroundTasks — BGTaskScheduler for daily sync
- UserNotifications — UNUserNotificationCenter for local notifications
- WebKit — WKWebView for embedded web pages
- SwiftUI — declarative UI
- AppIntents — Shortcuts integration

### Third-party libraries
None.

### Server dependencies
- Flask biotracker at `https://<YOUR_SERVER>`
- `/api/health-sync` endpoint
- `/api/flare-status` endpoint

---

## Versioning

**Current version:** 1.0
**iOS minimum:** 17.0
**Swift version:** 5.x

**Change log:**
- 2026-04-05 — Initial implementation

---

## Credits

**Developer:** Alaric Moore
**AI assistant:** Aplaude (Claude Opus)
**Spec author:** Alaric, with Wolf (Claude Opus)

---

## License

Personal project, no rights reserved. Code is for Alaric's personal health tracker system and is free to copy and use or whatever. 

---

## See also

- `XCODE_SETUP.md` — project configuration checklist
- `TESTING_GUIDE.md` — testing procedures
- `NOTIFICATIONS.md` — notification reference
