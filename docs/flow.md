# Tape: UX flow spec

Tape is a local-only menu bar recorder for calls. It records system audio and your microphone into a single track, and optionally the screen. Its guiding rule: **non-intrusive and easy**. It shows no window unless asked, sends no notifications, and adds no prompts beyond the ones macOS requires.

- macOS 26.0 deployment target, matching rinse and tidy. Nothing used here needs 27: process taps date from 14.2, `SCContentSharingPicker` from 14, and voice-processing ducking control from 14.
- Pure SwiftUI, no Dock icon (`LSUIElement`), no third-party packages, Liquid Glass only through system components.
- Not sandboxed, like rinse. Hardened runtime with `com.apple.security.device.audio-input`.
- The only network access is the existing GitHub releases `AppUpdater`.
- Sizes, padding and radii are multiples of 4 pt.

## 1. Surfaces

| Surface | What it is |
|---|---|
| Menu bar label | Idle: a glyph. Recording: a glyph plus the elapsed time |
| Menu | `MenuBarExtra` with `.menuBarExtraStyle(.menu)`, as in rinse. It has an idle variant and a recording variant |
| System content picker | `SCContentSharingPicker`, opened by Record Screen…. Tape has no picker UI of its own |
| Settings scene | `Settings` with a `TabView` of grouped `Form`s: General, About |
| Recording window | A small `Window` scene, shown only when Tape is reopened during a recording (§3) |
| System prompts | Microphone, then System Audio Recording, each shown once by macOS |

There is no onboarding window, no notification, and no post-recording window. Reopening the app from Finder, Spotlight or the Dock (`applicationShouldHandleReopen`) opens Settings when idle, using rinse's app-menu workaround, and the recording window while recording.

## 2. Capture pipeline (decisions that shape the UX)

| Part | Decision | Why |
|---|---|---|
| System audio | **Core Audio process tap** (`CATapDescription(monoGlobalTapButExcludeProcesses:)`, Tape's process object from `kAudioHardwarePropertyTranslatePIDToProcessObject`), read through a private aggregate device's IOProc, in both modes | It needs only the "System Audio Recording Only" permission, so an audio recording never shows a *screen* recording prompt. One audio path for both modes |
| Screen video | `SCStream` from the filter `SCContentSharingPicker` returns, video only | The person's pick is their consent, so no Screen Recording permission row and (to verify) no periodic Sequoia re-approval prompt |
| Microphone | `AVAudioEngine` input. Voice processing (`setVoiceProcessingEnabled`) when Reduce Echo is on, with `voiceProcessingOtherAudioDuckingConfiguration` set to no advanced ducking and `.min` ducking level | Teams and Zoom are ducked as little as the API allows (`.min` is the minimum, not zero; verify in the spike) |
| Mix | System audio and mic summed at equal gain, with a peak limiter to prevent clipping. No normalisation or auto-gain in v1 | Predictable. Speech-to-text copes with uneven levels |
| Sync | The tap and the mic run on different device clocks, which drift apart (tens of ms per hour is typical). Every buffer is stamped in host time (IOProc `inInputTime.mHostTime`, engine `AVAudioTime.hostTime`). The mic is aligned to the tap through a ring buffer keyed on host time and slowly resampled to follow the tap's clock. Gaps (device switch, engine restart) are filled with silence by timestamp, never by appending. The writer session starts at the first mixed sample's host time; `SCStream` video PTS are in the same host clock, so screen and audio line up without offsets | Without this the mic slides out of sync over a long call |
| Audio format | AAC, 48 kHz, mono, about 64 kbps (about 30 MB per hour) | Speech for AI summaries. Stereo adds nothing |
| Audio-only file | `.m4a` | Plays everywhere and is accepted by AI tools |
| Screen file | `.mov`, HEVC at 30 fps with the cursor, plus the mixed AAC track | The QuickTime-native container, supports fragments |
| Durability | `AVAssetWriter` with `movieFragmentInterval` of 10 s and `initialMovieFragmentInterval` of 1 s | A crash or power loss loses at most about 10 s (§8). Without the short first fragment, a crash in the first 10 s leaves an unplayable file |

**Build in layers.** Layer 1 is Record Audio → `.m4a` without voice processing: one aggregate device holding the tap *and* the mic as a sub-device, drift compensation on (`kAudioSubTapDriftCompensationKey`, `kAudioSubDeviceDriftCompensationKey`). One IOProc then delivers both sample-aligned on one clock, so layer 1 needs no ring buffer or resampler. Layer 2 moves the mic to the voice-processing engine (VPIO can't sit on that aggregate) and adds the Sync row above. Screen comes after.

**Spikes before building:**
1. `.m4a` (`AVFileType.m4a`) honours `movieFragmentInterval`. If it doesn't, write a fragmented MPEG-4 audio file (`AVFileType.mp4`, audio only) and name it `.m4a`. Also confirm `finishWriting` on a multi-hour fragmented file stays near 1 s (§3, §8 assume it). **Done:** `.m4a` writes `moof` fragments, and a writer killed at 35 s leaves a playable 31 s file. The `.mp4` fallback is worse (QuickTime tools see only the first 1 s fragment). `finishWriting` on a 3 hour file takes about 30 ms and consolidates it to a plain `moov` file. Feeding a running writer a new input sample rate silently truncates audio, so the capture path converts to 48 kHz itself.
2. Tap permission prompt: when exactly it appears (expected: the first `AudioDeviceStart` on an aggregate containing a tap, asynchronously, with zeros delivered until answered) and how denial shows (§5). **Layer 1 status, unverified on hardware:** the probe (rewriting `kAudioTapPropertyDescription`, expecting `kAudioDevicePermissionsError`) only runs once a previous recording has heard non-zero system audio, because nothing documents what it returns while the prompt is still open. So a denial at the very first prompt is caught only by the after-stop zero check.
3. **Reduce Echo actually removes other apps' audio.** VPIO's echo reference may be only what Tape itself plays, in which case Teams on speakers isn't cancelled at all. Test with a real Teams call on speakers. If it doesn't work, ship Reduce Echo off (or cut it) rather than colour everyone's voice for nothing.
4. Tape's voice processing doesn't degrade Teams' or Zoom's own mic input (a forum report says a VP-enabled recorder cut off Zoom's input) and doesn't audibly duck them.

## 3. Menu bar label

| State | Label | Accessibility description |
|---|---|---|
| Idle | `recordingtape` | "Tape" |
| Starting (prompts or writer setup in progress) | `recordingtape`, unchanged | "Tape, starting" |
| Recording | `record.circle` + `12:34` | "Tape, recording, 12 minutes" |
| Stopping (finalising, usually under 1 s) | `record.circle` + frozen time | "Tape, saving" |

- The recording label is drawn into a template `NSImage` (symbol, 4 pt gap, time), as tidy and spaces do. It's monochrome like every extra: no red dot, so it never imitates the system's privacy indicators (§10).
- Time format: `m:ss` under an hour, `h:mm:ss` after. Monospaced digits so the item doesn't jitter. The image redraws once a second.
- The accessibility description updates once a minute, not every second, so VoiceOver isn't flooded.
- The same glyph is used for audio and screen. The menu says which mode is running, and macOS's own indicator already signals screen capture.

**Push back: no in-app "Show menu bar icon" setting.** The menu is Tape's main way to start or stop a recording, so offering to hide it invites an unusable app mid-call.

**But the icon can still disappear.** macOS 26 lets people turn any item off in System Settings › Menu Bar, and macOS hides extras that don't fit (the label widens when the time appears, which on a notched MacBook can push it out of view mid-call). HIG: don't rely on extras being visible, and provide alternate access. Tape's fallback is reopen:

| Reopen (Finder, Spotlight, Dock) while | Opens |
|---|---|
| Idle | Settings, as today |
| Recording | The recording window: one line saying what's recording ("Recording audio" or `Recording "Microsoft Teams" and audio`), the elapsed time in monospaced digits, and a default-button **Stop Recording** (Return). Closes itself when the recording stops. Standard close button, no minimise or zoom |

Why a separate window rather than a Stop row in Settings: Settings holds rarely changed preferences (HIG) and its General form is long; a live control buried in it is hard to find, and the window title would still read "General". The window is one tiny SwiftUI view reusing the menu's state, and it never appears unless asked for. Starting a recording without the icon isn't covered in v1; App Intents "Record Audio" and "Stop Recording" are the v1.x complement (§11).

## 4. Menu

### Idle

| Item | Notes |
|---|---|
| Record Audio | Starts at once (after first-run prompts, §5) |
| Record Screen… | Opens the system picker. The ellipsis marks the extra step |
| *Status line* (disabled text, optional) | At most one, see the table below |
| *Status action* (optional) | For example "Open Privacy Settings…" |
| ── | |
| Show Last Recording in Finder | Selects the file. Disabled when there's none, or the file is gone |
| Open Recordings Folder | |
| ── | |
| Update items | Rinse's `UpdateMenuItems`, unchanged |
| Settings… ⌘, | `SettingsLink` |
| Quit Tape ⌘Q | |

Status lines, highest priority first. Each one persists until the next recording starts or its cause is fixed. None of them ever repeats as a prompt.

| Condition | Line | Action item |
|---|---|---|
| Microphone denied | Microphone access is off. | Open Privacy Settings… |
| System audio denied | System audio access is off. | Open Privacy Settings… |
| Last recording was recovered after a crash | Recovered "Tape 2026-10-26 at 14.03.05". | (Show Last Recording covers it) |
| Last recording stopped unexpectedly | Recording stopped: *reason* (§7) | (Show Last Recording covers it) |
| Last recording fell back to the default folder | Saved to Movies › Tape. "*Folder*" wasn't available. | |
| Last recording had no system audio | The last recording has no system audio. | Open Privacy Settings… (§5) |
| Not enough disk space to start | Not enough space on "*Volume*" to record. | |

### Recording

| Item | Notes |
|---|---|
| Stop Recording | First item, so one click on the label and one on Stop ends it |
| Recording audio · since 14:03 | Disabled. Screen mode: `Recording "Microsoft Teams" and audio` (window, app or display name from the picker) |
| Microphone: AirPods Pro | Disabled. Shows the live device (the system default input), or "Microphone unavailable" |
| ── | |
| Open Recordings Folder | |
| ── | |
| Update items | Install is disabled and retitled "Tape *x* installs after recording" (§8) |
| Settings… ⌘, | |
| Stop and Quit Tape ⌘Q | The title says exactly what Quit will do, so no confirmation dialog is needed |

- Record Audio and Record Screen… are replaced by Stop rather than disabled. A menu bar extra that swaps Record and Stop is the QuickTime pattern, and there is only ever one recording.
- The menu doesn't show live elapsed time: menus are snapshots, and the label already ticks.

### Pause: not in v1

Pausing needs timestamp surgery on both writer inputs and a resumed audio clock, plus a third label state. A call isn't a dictation: people rarely pause a meeting recording, and Stop then Record gives two well-named files. Revisit only if it's asked for.

## 5. Permissions

Tape asks for nothing at launch (HIG: request only when the feature is used). No pre-alert window: the click on Record is the context.

| Permission | Asked when | Purpose string | Status check |
|---|---|---|---|
| Microphone | First Record Audio or Record Screen… | "Tape records your voice alongside the call." | `AVCaptureDevice.authorizationStatus(for: .audio)` |
| System Audio Recording Only | Right after the mic is allowed, by macOS on the first `AudioDeviceStart` of the aggregate device holding the tap (`NSAudioCaptureUsageDescription`). The prompt is asynchronous: the IOProc already runs and receives zeros until it's answered | "Tape records what other people say in your calls." | No public API. Setting `kAudioTapPropertyDescription` reportedly fails with `kAudioDevicePermissionsError` when denied (one forum report, undocumented; verify in spike 2). Fallback: all-zero buffers |
| Screen Recording | Never | n/a | The picker grants per-pick access. **Spike:** confirm that no Screen Recording entry or monthly re-prompt appears on 26 |

`NSAudioCaptureUsageDescription` isn't in Xcode's key list and has been reported to be silently dropped when set through `INFOPLIST_KEY_*`. Put it in the Info.plist properties in `project.yml` and verify that it lands in the built plist.

**First recording, step by step:**
1. Click Record Audio. The macOS microphone prompt appears.
2. Allow. Tape starts the tap, the mic and the writer, and the label begins ticking. The macOS system audio prompt appears over it.
3. Allow. System audio flows from that moment; the first seconds of the file have only the mic. That makes two system dialogs in total, once ever.
4. In screen mode, the picker opens only after the system audio prompt is answered (Tape starts the tap first; spike 2 decides how it knows the prompt was answered), so the prompts never stack on top of it.

**Denied or revoked:**

| Case | Behaviour |
|---|---|
| Mic denied at the prompt | Nothing starts and nothing else appears (the person just said no). The idle menu shows the status line from §4 |
| System audio denied at the prompt | Stop at once and delete the file (it holds only the mic, which §5 rules out as a recording). Label back to idle, status line from §4. Detected by the probe or, failing that, by the zero check below |
| Record clicked while the mic is denied | Opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` directly. No alert, never a second nag |
| System audio denied | The same pattern, opening `Privacy_ScreenCapture` (the pane holds the "System Audio Recording Only" list; verify the anchor) |
| Both permissions required? | **Yes.** A call recording without the other side, or without you, is the wrong file. There's no mic-only or system-only mode in v1 |
| Revoked while recording | If macOS terminates Tape, crash recovery applies (§8). If the mic simply goes silent, keep recording, and the mic line in the menu reads "Microphone unavailable" |
| Granted later in System Settings | Picked up on `didBecomeActive` and the next menu open. The status line disappears |
| System audio silent although "allowed" | After a stop, if the system track of a recording over 60 s was all digital zero, show "The last recording has no system audio." once. This catches a revoked permission that the API missed. A tap also delivers digital zero when nothing is playing, so a recording with no call audio at all triggers it falsely; acceptable, since Tape is for calls |

Settings › General shows both rows using tinecast's `PermissionRow` pattern: label, reason, then a status ("Allowed" with a green checkmark, or "Not Allowed") and an "Open System Settings…" button when not allowed. "Allow…" only appears for the mic while it's still undetermined.

## 6. Starting a recording

| Step / case | Behaviour |
|---|---|
| Record Audio | Check the folder (§9) and free space. Start the tap and the mic, then the writer, then the label. Target under 0.5 s |
| Record Screen… | Present `SCContentSharingPicker` with modes single window, single app, and single display, excluding Tape. Recording starts the instant the person picks, with no countdown and no extra Record button, as with Screenshot's capture |
| Picker cancelled | Nothing happens: no message, no status line |
| Picked content later resized | The output size is fixed at pick time (backing-scale pixels). Later resizes scale to fit, letterboxed |
| A recording is already running | Impossible from the UI (§4) |

## 7. While recording: interruptions

Rule: **never stop because of a device change. Stop only when there's nothing left to record, then always finalise the file.**

| Event | Behaviour | Menu afterwards |
|---|---|---|
| Stop Recording | Finalise, label back to idle | Show Last Recording enabled. No status line |
| Stopped from the system screen-sharing indicator | Treated exactly like Stop Recording | Same |
| Shared content changed from the system screen-sharing menu (screen mode) | `contentSharingPicker(_:didUpdateWith:for:)` fires. Apply it with `updateContentFilter`; the output size stays fixed and the new content is letterboxed | The "Recording …" line shows the new name |
| Picked window closed or app quit (screen mode) | Finalise and save. This is also the natural end when the Teams meeting window closes | "Recording stopped: the window closed." |
| Picked display disconnected | Finalise and save | "Recording stopped: the display was disconnected." |
| The default input changes or is unplugged | Switch to the new default, insert silence for the gap so audio stays in sync | Mic line shows the new device |
| Output device changes | The tap is global, so capture continues. The voice-processing engine restarts on `AVAudioEngineConfigurationChange`, with a silence-filled gap | None |
| Idle sleep | Prevented while recording (`ProcessInfo.beginActivity` with `.idleSystemSleepDisabled`). The display may still sleep | n/a |
| Forced sleep (lid closed without an external display, Apple menu › Sleep) | Finalise on `willSleep`. No auto-resume on wake | "Recording stopped when your Mac went to sleep." |
| Screen locked | Keep recording. Calls continue while locked | n/a |
| Disk nearly full (checked every 30 s, below 200 MB) or writer error | Finalise what exists | "Recording stopped: "*Volume*" is full." / "...couldn't write to the file." |
| Save folder's volume ejected mid-recording | The writer errors, Tape keeps whatever fragments were written | "Recording stopped: "*Volume*" was disconnected." |

The idle menu shows these unexpected stops passively. The label going back to idle is the live signal. No notification (decided, §16).

## 8. Quit, update, crash

| Case | Behaviour |
|---|---|
| Stop and Quit, ⌘Q, logout, restart, shutdown | `applicationShouldTerminate` returns `.terminateLater`, finalises, then replies. Hard cap of 5 s, after which the fragmented file is still valid |
| Update staged while recording | The install item is disabled and reads "Tape *x* installs after recording". After Stop it goes back to "Install Tape *x* and Relaunch". The automatic `installOnQuit` runs in `applicationWillTerminate`, after finalising |
| Crash, force quit, power loss | Before the writer starts, store the in-progress file path in `UserDefaults`, and clear it on finalise. On next launch, if it's set and the file exists, keep the file (fragments make it playable), clear the marker, and make it the last recording |
| Recovered file shorter than 1 s or unreadable | Delete it silently. Nothing worth keeping |

The recovered file keeps its original name. The status line reads: Recovered "Tape 2026-10-26 at 14.03.05".

## 9. After stop: where the file goes

- **Default folder: `~/Movies/Tape`.** It's visible, so it can be fed to AI tools. Unlike Desktop and Documents, `~/Movies` isn't a TCC-protected folder (no third prompt), and it isn't synced by Desktop & Documents iCloud.
- **Naming:** `Tape 2026-10-26 at 14.03.05.m4a` / `.mov`. This mirrors Screenshot's format, uses the start time, and sorts chronologically by name. A collision (same second) appends ` 2`.
- The file gets its final name from the start. There's no temp file to move, so a crash leaves the file where people look.
- **Feedback:** none beyond the label returning to idle, plus Show Last Recording in Finder in the menu. No notification, no Finder window, no floating thumbnail. Clicking Stop is the feedback.

| Folder state at start | Behaviour |
|---|---|
| Default folder missing | Recreate it silently |
| Custom folder missing (for example an unmounted drive) or unwritable | Record to `~/Movies/Tape` instead. The recording menu's "Recording audio" line adds "· saving to Movies › Tape". The idle status line explains the fallback afterwards. Losing the call is worse than a different folder |
| Less than 1 GB free (screen) or 500 MB (audio) | Don't start. Show the status line from §4 |

## 10. System indicators

- macOS shows the orange microphone indicator and its own screen and audio capture indicator, and Control Center names Tape as the app recording. Tape doesn't duplicate or imitate them: no red dot, no coloured label.
- What Tape's label adds, which the system's don't: elapsed time, and a one-click Stop.
- **Verify in the spike:** which indicator a process tap shows on 26, so the docs and support answers are accurate.

## 11. Keyboard

- **No global shortcut in v1.** Hand-rolling `RegisterEventHotKey` is small, but it also needs a recorder UI, conflict handling, and a setting. That's not trivial, and it's against "easy".
- The menu's own shortcuts apply only while it's open: ⌘, and ⌘Q.
- **v1.x:** App Intents "Record Audio" and "Stop Recording". These give people a Shortcuts or Spotlight hotkey with no custom code, plus a way to *start* a recording when the icon is hidden (the recording window in §3 only covers stopping). Tape would be the right app for a Control Center control next (rinse already has the pattern).

## 12. Settings

Two tabs, grouped `Form`s, rinse's layout.

**General**

| Section | Control | Notes |
|---|---|---|
| Recordings | Save to: folder pop-up showing "Tape (Movies)", with Choose… and Show in Finder | Applies from the next recording. Desktop, Documents, Downloads, external drives and network volumes each trigger one macOS folder-access prompt on first write. Tape triggers it right after Choose… (a test write), so it never appears mid-call |
| Microphone | Toggle: Reduce Echo, **on by default**. Description: "Removes other people's voices from your microphone when you're on speakers." | See §14 |
| Permissions | Microphone row, System Audio row (§5) | tinecast `PermissionRow` style |
| (none) | Launch at login | rinse's `SMAppService` block, including the "Approval needed" state |
| Updates | rinse's Updates section unchanged | |

**About:** rinse's `AboutSettings`, with the tagline "Records your calls and screen, on this Mac only."

Removed or never added: Show menu bar icon (§3), audio format and quality, file naming, countdown, and the notification toggle. Nothing in Settings changes a recording in progress.

## 13. Accessibility

- Every menu item is a plain text `Button` or `Text`, so VoiceOver reads it as is. Status lines are full sentences.
- Label: see §3, updated per minute.
- The label changes silently, so Tape posts a VoiceOver announcement (`AccessibilityNotification.Announcement`) "Recording started" and "Recording saved" (or the stop reason). Only VoiceOver users hear it.
- Stop Recording is always first in the recording menu, so it's reached with a single VO-Down.
- The permission rows hide their status icon from accessibility (the text carries it), as tinecast does.

## 14. Teams and Zoom interplay

| Situation | What happens | Tape's handling |
|---|---|---|
| Teams and Tape both open the mic | macOS shares input devices. Tape never changes the system default input or output, so Teams' input is untouched | None needed |
| You're on speakers | Without echo cancellation, Tape's mic hears the far end from the speakers. The system track already has it, so the mix doubles every remote voice with a small delay, which hurts transcription | Reduce Echo on by default. Voice processing uses the output as its reference |
| You're on headphones | No echo. Voice processing is harmless but slightly colours your voice | People can turn Reduce Echo off |
| Voice processing would duck Teams | Ducking is disabled (§2) | n/a |
| Teams' own voice isolation or noise suppression | Affects only what Teams *sends*. Tape gets the raw mic. With voice processing on, macOS's Mic Mode (Control Center) also applies to Tape, where people can choose Voice Isolation themselves | No Tape UI |
| AirPods already used by Teams as mic | Already in HFP (low quality) because of Teams. Tape opening the same mic changes nothing | None |
| AirPods are output, but Teams uses another mic, and AirPods are the system default input | Tape opening the AirPods mic drops AirPods to HFP mid-call | Not handled in v1: Tape always uses the system default input. Change the default input in System Settings › Sound |
| Teams muted | **Tape still records your mic.** Tape doesn't know about Teams' mute | Called out on the About tab and in the README. Not in the menu |
| System sounds, other apps' audio | Recorded too, because the tap covers all processes except Tape | Per-app audio is out of scope |

## 15. Out of scope for v1

- AI transcription or summaries, uploading, any network use besides updates
- Editing, trimming, a recordings library, playback inside Tape
- Separate mic and system tracks, stereo, quality settings
- Pause and resume
- Camera overlay, area selection, click highlighting, system-audio-only or mic-only modes
- A global hotkey, App Intents, a Control Center control (v1.x candidates)
- Notifications
- Detecting call start and auto-recording
- Per-app audio capture
- Older macOS than 26

## 16. Decided

- System audio through a Core Audio process tap; ScreenCaptureKit only for screen video via the system picker.
- Unexpected stops are shown passively in the menu (§4, §7). No notifications.
- Default folder `~/Movies/Tape`.
- Tape always records the system default input. There's no microphone picker in v1: it follows whatever System Settings › Sound uses, including changes mid-recording.
