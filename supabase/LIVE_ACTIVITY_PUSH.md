# Bloom: synced Live Activity and partner-alert pushes

The iOS app only **registers tokens** in `public.device_tokens`. Your push Edge Function
reads them and sends APNs requests. Without that function, each phone still starts and
updates its own Live Activity locally whenever the app runs.

- Bundle ID: `app.businessgliders.bloom` (widget extension: `app.businessgliders.bloom.bloomwidget`)
- APNs topic for Live Activities: `app.businessgliders.bloom.push-type.liveactivity`
- APNs topic for partner alerts: `app.businessgliders.bloom`
- Auth: token-based (.p8 key, team ID, key ID). The same key works for both hosts.

## Token rows (`device_tokens`)

Columns the app writes: `token`, `type`, `user_id`, `pregnancy_id`, `activity_id`, `environment`.
Rows are unique on `(token, type)`; the app upserts on that pair.

- `apns`: device token for normal notifications. **It's only present while that person has
  "Partner alerts" turned on in Settings.** No row means no alerts. `activity_id` is null.
- `live_activity_start`: push-to-start token (iOS 17.2+), one per phone, `activity_id` null.
  Use it to start an activity on a phone that has none running for that taker.
- `live_activity_update`: one row per running activity, from `activity.pushTokenUpdates`.
  `activity_id` = `"{takerID}:{activityID}"`. The part before `:` is the lowercased `user_id`
  of the person whose meds the activity shows; the part after is ActivityKit's activity id.
  The app deletes this row when the activity ends or is dismissed.

`environment` is `sandbox` or `production`. **Send each token to the matching APNs host**;
a token sent to the wrong host fails with `BadDeviceToken`.
- `sandbox` → `https://api.sandbox.push.apple.com` (simulator, Xcode/debug and development-signed builds)
- `production` → `https://api.push.apple.com` (TestFlight and App Store builds)

The app decides it per build: simulator or Debug → sandbox; a build with an embedded
provisioning profile follows that profile's `aps-environment`; TestFlight/App Store builds
(no embedded profile) → production.

Tokens are lowercase hex strings. Rows are removed on sign out, Leave pregnancy and Delete account.
On an APNs `410` or `BadDeviceToken` from the correct host, delete that row.

## Who gets what

A phone gets a Live Activity or alert for a medication only if its user **follows it live**:
`medication_follows.mode = 'live'` for `(medication_id, user_id)`. A missing row means
the default:
- the taker → live
- the partner viewing a med that mom takes → live
- otherwise → `app_only`

`app_only` means no Live Activity, no reminders and no partner alerts for that med on that phone.

## Live Activity types

Attributes type name (use exactly): **`BloomActivityAttributes`**.
**All dates are Unix seconds (JSON numbers).** ISO 8601 strings are also accepted when decoding.

Attributes (static, sent only on `start`):
- `momName`: string
- `takerID`: string, the lowercased `user_id` of the person taking these meds
- `takerName`: string, shown as "{takerName}: no food for …" on the other person's phone
- `takerRole`: string, `"mom"` or `"partner"`

Content state (`content-state`):
- `dose`: object, optional. The dose that needs attention (due now, or coming up within 60 min).
  - `medID`: string (medication UUID)
  - `scheduledAt`: number (Unix seconds)
  - `name`: string (short/friendly name)
  - `emoji`: string
  - `detail`: string. Free text from the med's dose field. **Send `""` from the server**: no amounts in pushes.
  - `isDue`: bool. True = the time has passed; false = upcoming.
- `otherDueCount`: int. Other doses also due now (default 0).
- `windowStart`: number, optional. Start of a **confirmed** no-food window (counted from the real taken time).
- `windowEnd`: number, optional. Its end. Send both or neither.
- `windowReason`: string, optional, e.g. `"Iron"` or `"Iron & Thyroid"`
- `resolved`: int. Doses taken or skipped today for this taker.
- `total`: int. Doses scheduled today for this taker.
- `staleReason`: string, `"windowEnds"`, `"doseDue"` or `"none"`. What becomes true at `stale-date`.

Missing optional fields decode as absent; missing ints decode as 0.

## Payloads

Headers for all Live Activity pushes: `apns-push-type: liveactivity`,
`apns-topic: app.businessgliders.bloom.push-type.liveactivity`, `apns-priority: 10`
(use `5` for low-importance updates to save budget).

### Start (to a `live_activity_start` token)

Send only if that phone has no `live_activity_update` row whose `activity_id` starts with the same `takerID`.

```json
{
  "aps": {
    "timestamp": 1763107200,
    "event": "start",
    "content-state": {
      "dose": null,
      "otherDueCount": 0,
      "windowStart": 1763107200,
      "windowEnd": 1763114400,
      "windowReason": "Iron",
      "resolved": 1,
      "total": 1,
      "staleReason": "windowEnds"
    },
    "attributes-type": "BloomActivityAttributes",
    "attributes": {
      "momName": "Maya",
      "takerID": "a1b2c3d4-…-lowercased-user-uuid",
      "takerName": "Maya",
      "takerRole": "mom"
    },
    "alert": { "title": "Maya took Iron", "body": "No food until 15:21" },
    "stale-date": 1763114400
  }
}
```

`alert` is required by iOS for push-to-start. Once started, the phone registers the
activity's own update token in `device_tokens` (`live_activity_update`).

### Update (to that activity's `live_activity_update` token)

```json
{
  "aps": {
    "timestamp": 1763110000,
    "event": "update",
    "content-state": {
      "dose": {
        "medID": "6F1C…-UUID",
        "scheduledAt": 1763110800,
        "name": "Thyroid",
        "emoji": "💊",
        "detail": "",
        "isDue": false
      },
      "otherDueCount": 0,
      "windowStart": 1763107200,
      "windowEnd": 1763114400,
      "windowReason": "Iron",
      "resolved": 1,
      "total": 2,
      "staleReason": "doseDue"
    },
    "stale-date": 1763110800
  }
}
```

No `attributes*` on update. `alert` is optional (only to make it light up the screen).
`timestamp` must increase; iOS ignores older ones.

### End (to that activity's `live_activity_update` token)

```json
{
  "aps": {
    "timestamp": 1763114400,
    "event": "end",
    "content-state": {
      "otherDueCount": 0,
      "resolved": 1,
      "total": 1,
      "staleReason": "none"
    },
    "dismissal-date": 1763114700
  }
}
```

End when nothing is due or upcoming within 60 min and no confirmed window is running.
`dismissal-date` keeps the final "All done" state on the Lock Screen briefly (omit to use
iOS's default of up to 4 hours; use a past time to remove it now).

## Partner alerts

When a `dose_logs` row is inserted or updated to `status = 'taken'`:
1. Find the med's taker (`medications.taken_by`).
2. Send to the **other** member's `apns` token(s), only if that member follows the med live.
3. Text (use `profiles.display_name` or the pregnancy's mom/partner name, and the med's
   `friendly_name`, falling back to `name`):
   - `{taker} took her {medication}` when the taker is mom (for example "Maya took her prenatal vitamin")
   - `{taker} took his {medication}` when the taker is the partner
   - If `logged_by` isn't the taker, add ` · logged by {name}`.
   - **No-food window:** when the med has `no_food_after_min > 0` and
     `taken_at + no_food_after_min` is still in the future, append ` · no food until {h:mm}`,
     for example "Jaismine took her Thyroid · no food until 8:31". Format `{h:mm}` in the taker's
     `notification_prefs.time_zone` (falling back to the recipient's, then UTC), 12-hour without AM/PM.
     Also add `"no_food_until": <unix seconds>` to the payload. Send it with
     `"interruption-level": "time-sensitive"` in `aps`.
   - Keep the Live Activity update push for the same log (windowStart/windowEnd), so the partner's
     Live Activity shows the same countdown. The partner's phone shows no popup.

Headers: `apns-push-type: alert`, `apns-topic: app.businessgliders.bloom`, `apns-priority: 10`.

```json
{
  "aps": {
    "alert": { "title": "Bloom", "body": "Maya took her Iron" },
    "sound": "default",
    "thread-id": "pregnancy-ab9f9e7d-f6c7-49a4-9d24-5dfe5e1afe4c"
  },
  "type": "dose_taken",
  "medication_id": "d5606a56-4ce4-4cc2-a45e-e34b3c063ff2",
  "pregnancy_id": "ab9f9e7d-f6c7-49a4-9d24-5dfe5e1afe4c"
}
```

The app refreshes its data when an alert arrives in the foreground. The extra keys
(`type`, `medication_id`, `pregnancy_id`) are optional context; the app doesn't require them.

Never include dose amounts or strengths in a push.
