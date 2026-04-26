# SardinesSync

iOS companion app for the SardinesTrack Flask server. Syncs HealthKit data to the server, fetches flare-risk forecasts, and embeds the Log and Risk pages via WKWebView.

## What it does

- TabView with Sync, Log, and Risk tabs
- WKWebView for the biotracker Log and Risk mobile pages
- HealthKit sync, manual and automatic
- Daily background sync via `BGTaskScheduler`
- Local notifications: bedtime, med doses, flare alerts
- Flare-status API client (`/api/flare-status`)
- iOS Shortcuts actions
- Historical backfill
- Settings UI

## Setup

### Flask side

The server must expose `/api/flare-status`, returning JSON like:

```json
{
  "ok": true,
  "date": "2026-04-05",
  "score": 7.2,
  "predicted_flare": false,
  "score_delta": 2.1,
  "factors": [...],
  "doses_due": [...]
}
```

Auth uses the same Bearer token as `/api/health-sync`. Smoke test:

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
  "https://<YOUR_SERVER>/api/flare-status?user_id=1"
```

### Xcode

Full checklist lives in `XCODE_SETUP.md`. Minimum config:

**Info.plist keys** (Target → Info)

| Key | Value |
|-----|-------|
| `BGTaskSchedulerPermittedIdentifiers` | array containing `com.biotracking.healthsync.daily` |
| `NSHealthShareUsageDescription` | description of why HealthKit access is needed |

**Capabilities** (Target → Signing & Capabilities)

- HealthKit, with Background Delivery on
- Background Modes, "Background processing" only

**Entitlements** (`healthsync.entitlements`)

```xml
<key>com.apple.developer.healthkit</key>
<true/>
<key>com.apple.developer.healthkit.background-delivery</key>
<true/>
```

### First run

1. Build to a real iPhone. HealthKit does not work in the Simulator.
2. Sync tab → Authorize HealthKit → grant permissions.
3. Fill in the settings:
   - Server URL: `https://<YOUR_SERVER>/api/health-sync`
   - API Token: from Flask config
   - User ID: `1`
4. Tap Sync Health Data. Expect a status line like `synced 9 fields: steps, hrv, ...`.
5. Log tab loads the biotracker log page. Risk tab loads the forecast page.

For the full test matrix (notifications, background sync, Shortcuts), see `TESTING_GUIDE.md`.

## Troubleshooting

### HealthKit not authorized

- Must be a real iPhone, not the Simulator
- Health app → Sharing → Apps → healthsync should list permissions
- Info.plist must include `NSHealthShareUsageDescription`

### Sync fails with a network error

- Check Tailscale is connected on the iPhone
- Open `https://<YOUR_SERVER>` in Safari to confirm reachability
- Confirm the Flask server is running

### Web views show a blank page

- Same Tailscale check as above
- Try disconnecting and reconnecting Tailscale

### No notifications

- Settings → Notifications → healthsync → Allow Notifications must be on
- If the first-launch prompt was dismissed, re-enable via the in-app toggle

### Background sync stays silent

- `BGTaskScheduler` is unreliable from Xcode debug builds; behavior is more consistent in TestFlight or production
- Settings → General → Background App Refresh → healthsync must be on
- `TESTING_GUIDE.md` documents the Xcode debug command to force a run

## File reference

Swift sources:

| File | Purpose |
|------|---------|
| `healthsyncApp.swift` | App entry point, registers background tasks |
| `ContentView.swift` | Main TabView |
| `SyncSettingsView.swift` | Settings and manual sync UI |
| `BioTrackerWebView.swift` | WKWebView wrapper for mobile pages |
| `HealthSyncer.swift` | HealthKit queries and network sync |
| `BackgroundSyncTask.swift` | Daily sync via `BGTaskScheduler` |
| `FlareChecker.swift` | Polls `/api/flare-status`, evaluates alerts |
| `NotificationManager.swift` | Schedules notifications |
| `ShortcutIntents.swift` | iOS Shortcuts actions |

Docs:

| File | Purpose |
|------|---------|
| `ARCHITECTURE.md` | System design and data flows |
| `XCODE_SETUP.md` | Xcode configuration checklist |
| `TESTING_GUIDE.md` | Test procedures |
| `NOTIFICATIONS.md` | Notification design and timing |
| `STATUS.md` | Implementation status |
| `Info.plist.reference` | Example Info.plist keys |
