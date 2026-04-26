# Notification Reference

What each notification type looks like when delivered, and how it's wired up.

---

## 1. Bedtime log reminder

**Category:** `BEDTIME_LOG`
**Trigger:** Daily, repeating at configured hour (default 9:00 PM)
**Badge:** None (could surface count of unlogged days later)

### Appearance
```
┌─────────────────────────────────────┐
│  healthsync                  9:00 PM│
│                                     │
│  Time to log                        │
│  How was today?                     │
└─────────────────────────────────────┘
```

### Behavior
- Tap: opens app to Log tab
- Swipe away: dismissed (will repeat tomorrow)
- Long press: shows notification options (Turn Off, Settings)

### Implementation
```swift
let content = UNMutableNotificationContent()
content.title = "Time to log"
content.body = "How was today?"
content.sound = .default
content.categoryIdentifier = "BEDTIME_LOG"
```

---

## 2. Medication dose reminder

**Category:** `MED_DOSE`
**Trigger:** Specific time based on dose schedule from `/api/flare-status`
**Schedule:** Once per dose, for tomorrow's doses

### Appearance
```
┌─────────────────────────────────────┐
│  healthsync                  8:00 AM│
│                                     │
│  Medication Reminder                │
│  Time for 4mg methylprednisolone    │
└─────────────────────────────────────┘
```

### Behavior
- Tap: opens app to Log tab (where doses are logged)
- Swipe away: dismissed (won't repeat — one-time notification)

### Implementation
```swift
for dose in doses {
    let content = UNMutableNotificationContent()
    content.title = "Medication Reminder"
    content.body = "Time for \(dose.doseLabel) \(dose.drugName)"
    content.sound = .default
    content.categoryIdentifier = "MED_DOSE"
    // Scheduled for tomorrow at dose.scheduledTime
}
```

### Example doses
- 8:00 AM — "Time for 4mg methylprednisolone"
- 12:00 PM — "Time for 4mg methylprednisolone"
- 4:00 PM — "Time for 4mg methylprednisolone"
- 8:00 PM — "Time for 4mg methylprednisolone"

(Typical medrol pack taper schedule.)

---

## 3. Flare risk alert — threshold crossed

**Category:** `FLARE_THRESHOLD`
**Trigger:** Immediate, when evening sync detects `predicted_flare == true`
**De-duplication:** Won't re-alert same day

### Appearance
```
┌─────────────────────────────────────┐
│  healthsync                     Now │
│                                     │
│  Flare Risk Elevated                │
│  Flare risk is elevated — score 9.2/│
│  20. Take it easy tomorrow.         │
└─────────────────────────────────────┘
```

### Behavior
- Tap: opens app (no specific tab)
- High priority: default sound, shows on lock screen

### Implementation
```swift
let content = UNMutableNotificationContent()
content.title = "Flare Risk Elevated"
content.body = "Flare risk is elevated — score \(score)/\(maxScore). Take it easy tomorrow."
content.sound = .default
content.categoryIdentifier = "FLARE_THRESHOLD"
```

### When it fires
- Server calculates flare score >= threshold (default 8.0)
- Returns `predicted_flare: true` in `/api/flare-status`
- Background sync evaluates the condition and schedules the notification
- Typical timing: 8–10 PM (during the background sync window)

---

## 4. Flare risk alert — rapid trend

**Category:** `FLARE_TREND`
**Trigger:** Immediate, when evening sync detects `score_delta >= threshold` (default 3.0)
**De-duplication:** Won't re-alert same day

### Appearance
```
┌─────────────────────────────────────┐
│  healthsync                     Now │
│                                     │
│  Risk Score Rising                  │
│  Risk score jumped +3.5 today —     │
│  watch for flare signals.           │
└─────────────────────────────────────┘
```

### Behavior
- Tap: opens app (no specific tab)
- High priority: default sound, shows on lock screen

### Implementation
```swift
let content = UNMutableNotificationContent()
content.title = "Risk Score Rising"
content.body = "Risk score jumped +\(delta) today — watch for flare signals."
content.sound = .default
content.categoryIdentifier = "FLARE_TREND"
```

### When it fires
- Server calculates today's score minus yesterday's score >= 3.0
- Returns `score_delta: 3.5` (or higher) in `/api/flare-status`
- Background sync evaluates and schedules
- Can fire same evening as a threshold alert (independent conditions)

---

## Alert combinations

Multiple alerts can land in one evening:

### Example: bad day
```
8:30 PM — "Risk Score Rising" (delta +3.5)
8:30 PM — "Flare Risk Elevated" (score 9.2/20)
9:00 PM — "Time to log" (bedtime reminder)
```

Each carries different information:
- Trend alert — things got worse quickly today
- Threshold alert — absolute risk level is high
- Bedtime reminder — time to log the day

---

## Notification timing

### Scheduled (repeating)
- Bedtime log: daily at configured hour (9:00 PM default)

### Scheduled (one-time)
- Med doses: tomorrow at specific times (8:00 AM, 12:00 PM, etc.)

### Immediate (during background sync)
- Flare threshold: fires during evening sync (~8–10 PM)
- Flare trend: fires during evening sync (~8–10 PM)

---

## Testing notifications

### Quick test (10-second delay)
Add to `SyncSettingsView` for testing:
```swift
Button("Test Notification") {
    let content = UNMutableNotificationContent()
    content.title = "Test Alert"
    content.body = "This is a test notification"
    content.sound = .default

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
    let request = UNNotificationRequest(identifier: "test", content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(request)
}
```

### View scheduled notifications
```swift
Button("Show Scheduled") {
    UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
        print("Scheduled notifications:")
        for req in requests {
            print("- \(req.identifier): \(req.content.title)")
        }
    }
}
```

### View delivered notifications
```swift
Button("Show Delivered") {
    UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
        print("Delivered notifications:")
        for notif in notifications {
            print("- \(notif.request.content.title)")
        }
    }
}
```

---

## Notification permissions

System prompt on first launch:

```
┌─────────────────────────────────────┐
│  "healthsync" Would Like to Send    │
│  You Notifications                  │
│                                     │
│  Notifications may include alerts,  │
│  sounds, and icon badges. These     │
│  can be configured in Settings.     │
│                                     │
│     [ Don't Allow ]  [ Allow ]      │
└─────────────────────────────────────┘
```

If user taps "Don't Allow":
- Master toggle in app settings shows OFF
- Tapping the toggle prompts to open Settings
- User must enable in iOS Settings → Notifications → healthsync manually

If user taps "Allow":
- All notification types enabled by default
- Configurable in app settings (enable/disable, change times)
- Can also be customized in iOS Settings (sounds, badges, etc.)

---

## Settings hierarchy

### App-level (SyncSettingsView)
- Master toggle — enable/disable all notifications
- Bedtime hour — when to send the log reminder
- Sync hour — when to run background sync (affects flare alert timing)
- Trend threshold — how much delta triggers a trend alert

### iOS system (Settings → Notifications → healthsync)
- Allow Notifications — master on/off
- Show in Notification Center
- Sounds
- Badges
- Show on Lock Screen
- Show in CarPlay
- Notification Grouping (Automatic / By App / Off)

### Focus modes
Settings → Focus → [Mode] → Apps → healthsync. Allow or silence per Focus mode (Sleep, Work, etc.).

---

## Accessibility

### VoiceOver
All notifications are VoiceOver-compatible — speaks title and body, navigable to the app via tap.

### Font size
Notifications respect iOS Dynamic Type. Body text may truncate when very long.

### Reduce motion
Notification banners fade in instead of sliding when Reduce Motion is enabled.

---

## Best practices

### Keep body text concise
- Notifications truncate after ~150 characters
- Most important info should be in the first ~60 characters
- Use em dash (—) instead of hyphen (-) for readability

### Actionable information
- Tell the user what to do: "Take it easy tomorrow"
- Give context: "score 9.2/20" rather than "high risk"
- Be specific: "4mg methylprednisolone" rather than "your med"

### Avoid notification fatigue
- De-duplicate: don't re-alert same day
- Consolidate: one notification per event, not multiple
- Respect user settings: honor the master toggle

### Timing
- Bedtime reminder: after dinner, before bed (9 PM works well)
- Med reminders: at actual dose times, not "you have doses today"
- Flare alerts: evening, so the user can plan tomorrow

---

## Future enhancements (not implemented)

### Notification actions
Quick actions on notifications:

Med dose:
- "Mark Taken" — POST to server without opening the app
- "Skip Dose" — log as skipped

Bedtime log:
- "Log Now" — deep link with quick entry form
- "Remind Me in 30 Min" — snooze

Flare alert:
- "View Risk Factors" — open to Risk tab
- "Dismiss" — standard dismissal

### Rich notifications
- Attach a small chart image showing the score trend
- Show an icon for the med type

### Notification grouping
- Group all med doses under one expandable notification
- Separate thread IDs for flare alerts vs reminders

### Critical alerts
- For very high flare risk (score > 15?)
- Bypasses Do Not Disturb
- Requires special entitlement

---

## Content guidelines

### Title
- 3–5 words max
- Action-oriented or state-indicating
- Good: "Time to log", "Medication Reminder", "Flare Risk Elevated"
- Avoid: "healthsync notification", "You have an alert"

### Body
- One sentence preferred, two max
- Include actionable data (numbers, specifics)
- End with what the user should do
- Good: "How was today?", "Time for 4mg methylprednisolone", "Risk score jumped +3.5 today — watch for flare signals."
- Avoid: "You should check the app", "Something happened with your biotracker account"

### Sound
- Use `.default` for most notifications
- Consider silent for low-priority info
- Critical alerts get a special sound (not implemented)

---

## Debugging

### Notifications not appearing

Check 1: permission granted?
```swift
UNUserNotificationCenter.current().getNotificationSettings { settings in
    print("Authorization status: \(settings.authorizationStatus)")
    // .authorized   = good
    // .denied       = user declined
    // .notDetermined = haven't asked yet
}
```

Check 2: notification scheduled?
```swift
UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
    print("Pending: \(requests.count)")
    for req in requests {
        print("- \(req.identifier) at \(req.trigger?.nextTriggerDate())")
    }
}
```

Check 3: Focus mode blocking?
- Check Control Center for the Focus indicator
- Disable temporarily to test

Check 4: delivered but cleared?
```swift
UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
    print("Delivered: \(notifications.count)")
}
```

### Duplicate notifications

Symptom: same notification fires multiple times.
Cause: not removing old requests before scheduling new ones.
Fix: call `removePendingNotificationRequests()` first.

```swift
// Remove old bedtime reminders before scheduling a new one
center.removePendingNotificationRequests(withIdentifiers: ["bedtime_log_daily"])
```

### Wrong timing

Symptom: notification fires at unexpected time.
Cause: timezone mismatch or calendar component error.
Fix: always use `Calendar.current` and verify components.

```swift
var components = DateComponents()
components.hour = 21
components.minute = 0
// Use the current calendar, not UTC
let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
```

---

## Summary

Four notification types, each with a distinct purpose:

1. Bedtime log — habit formation (daily log entry)
2. Med doses — medication adherence (take on time)
3. Flare threshold — risk awareness (score crossed threshold)
4. Flare trend — early warning (rapid score increase)

All scheduled locally (no server push). All respect user preferences. All carry actionable information.
