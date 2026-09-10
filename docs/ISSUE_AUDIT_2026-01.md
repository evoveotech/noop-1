# Issue Audit — 2026-01

This document records the results of an audit of open issues and PRs against the current `main` branch.

## Issues verified fixed (ready to close)

Each issue below has been verified against the current `main` branch. The fix is present, complete, and covered by tests where applicable.

### BLE / Connection

| Issue | Title | Evidence |
|-------|-------|----------|
| #1193 | Duplicate device entries — removal doesn't stick | `forgetDevice` hard-delete in `BLEManager.swift` and `WhoopBleClient.kt` |
| #1635 | WHOOP 5/MG never bonds (CLIENT_HELLO suppression) | `HelloSuppression.swift` / `HelloSuppression.kt` with tests |
| #1833 | Serial hidden in hex payload walks past redaction | Hex redaction in `FrameRouter.swift` / `WhoopBleClient.kt` with tests |

### UI / UX

| Issue | Title | Evidence |
|-------|-------|----------|
| #1488 | Can't edit a workout duration | `editWorkout` in `WorkoutsView.swift` / `WorkoutsScreen.kt` |
| #1913 | Split body measurement / exercise distance units | Separate settings in `SettingsView.swift` / `SettingsScreen.kt` |

### Skin temp / Sleep

| Issue | Title | Evidence |
|-------|-------|----------|
| #930 | REM latency guard varies 7-85 min | `remLatencyGuard` in minutes since onset, `SleepStager.swift` / `.kt` |
| #1801 | No HR-only staging fallback | HR-only sleep staging in `SleepStager.swift` / `.kt` with `hrOnly` flag |
| #1849 | Fahrenheit WHOOP export stored as °C | `#1849` comment in `WhoopExportImporter.swift`, °F→°C conversion |
| #1851 | Skin-temp backfill for nights outside 21-night window | `SkinTempBackfillWalker.swift` / `SkinTempBackfill.swift` (commit b3b68e1dc) |
| #1853 | Apple skin-temp absolute backfill | Same as #1851, both platforms |
| #1884 | HR-only night HRV discarded | `#1884` comment in `AnalyticsEngine.swift`, guard removed |

### Backup / HR / Workout

| Issue | Title | Evidence |
|-------|-------|----------|
| #651 | Raw capture export blocks main actor | `#646/#651` in `FileExport.swift`, `Task.detached` |
| #652 | PuffinFrameRecorder main-actor work | `#652` in `PuffinFrameRecorder.swift`, background actor |
| #1195 | Live distance/pace + Health Connect import | `LiveScreen.kt`, `HealthConnectImporter.kt` DistanceRecord |
| #1410 | Backup app-build provenance | `BackupProvenance.swift` / `BackupProvenance.kt` with tests |
| #1760 | Pre-sleep HR baseline feedback | `PreSleepHeartRateFeedback.swift` / `.kt` with tests |
| #1770 | Standard HR persistence | `StandardHRMapping.swift` / `StandardHrMapping.kt` with tests |
| #1784 | Pre-sleep HR Android twin | `PreSleepHeartRateFeedback.kt` with tests |

### i18n / Alarm / Scoring

| Issue | Title | Evidence |
|-------|-------|----------|
| #557 | Android: hardcoded English suffixes | 0 remaining `uiString(...) + "English tail"` concatenations |
| #922 | 79 localized paragraphs with hardcoded English | 0 remaining (same fix as #557) |
| #1858 | Phone alarm per-day wake times | `WindDownNudge.perDayWakeOverrides` / `WindDownScheduler.kt` |
| #1863 | Wind-down nudge day shift | `#1863` in `WindDownNudge.swift`, `nudgeDayShift`/`shiftedWeekday` |
| #1864 | Per-day wake times not affecting alarm backup | `#1864` in `AppModel.swift`, `overrides` parameter |

### Analytics / Streak

| Issue | Title | Evidence |
|-------|-------|----------|
| #569 | Streak tracking | `StreakCalculator.swift` / `.kt` with tests + UI |
| #1298 | Clinician export | `RhythmExport.swift` / `.kt` with UI + tests |

## PRs verified fixed (ready to close)

| PR | Title | Evidence |
|----|-------|----------|
| #1587 | Record app build provenance for computed scores (closes #1410) | `BackupProvenance` already in main |
| #506 | Restore recognizable Android dashboard metric icons | `keyMetricIcon` in `TodayScreen.kt` |
| #531 | Add personalized HR zone thresholds (closes #138) | `personalizedHrZone` in `SettingsScreen.kt` / `Profile.swift` |
| #419 | Battery alerts never requested OS notification permission | `BatteryNotifier.requestAuthorization()` |
| #90 | Scroll-reactive bottom bar (refs #86) | `bottomBarAutoHide` in `RootTabView.swift` / `MainActivity.kt` |

## Issues left open (not verified fixed)

The following issues were reviewed but no complete fix was found in `main`:

#34, #52, #74, #92, #93, #112, #150, #160, #235, #257, #261, #271, #278, #287, #345, #364, #423, #477, #520, #550, #612, #613, #652, #700, #715, #730, #731, #745, #761, #796, #802, #836, #844, #851, #905, #920, #981, #982, #1118, #1146, #1169, #1244, #1300, #1303, #1304, #1331, #1342, #1413, #1451, #1466, #1617, #1821, #1829, #1832, #1835, #1836, #1839, #1844, #1848, #1855, #1862, #1883, #1997, #2013, #2026, #2041
