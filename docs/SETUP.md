# Setup and installation

This guide covers installing both halves of androcall, pairing them, granting the
permissions, and what to do when something goes wrong. For problems, see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## Requirements

| | |
|---|---|
| Mac | macOS 12 Monterey or later, Intel or Apple Silicon |
| Phone | Android 12 (API 31) or later, with Bluetooth Low Energy |
| Bluetooth | A phone already paired with the Mac in System Settings |

androcall needs a **paired** phone. macOS only allows pairing from its own System
Settings, so this one step cannot be done from inside an app.

## 1. Install the macOS app

Download the installer for your Mac from the
[releases page](https://github.com/JivinSardine/androcall/releases):

| File | For |
|---|---|
| `androcall-macOS-Apple-Silicon-arm64.dmg` | M1/M2/M3/M4/M5 Macs |
| `androcall-macOS-Intel-x86_64.dmg` | Intel Macs |
| `androcall-macOS-Universal.dmg` | Either (larger download) |

Open the `.dmg` and drag **androcall** into Applications, then eject the disk image.

### "The app is damaged and can't be opened"

The current builds are **ad-hoc signed**, not signed with a Developer ID and not
notarised. Gatekeeper therefore refuses to open them on the first try. Open the app
with **right-click › Open** and confirm, or run:

```bash
xattr -dr com.apple.quarantine /Applications/androcall.app
```

This is expected for an unsigned build and is **not** a sign of tampering. The
release assets are published with SHA-256 checksums; compare them if you want to be
sure the download is intact:

```bash
shasum -a 256 androcall-macOS-Apple-Silicon-arm64.dmg
# compare with the SHA256SUMS.txt from the same release
```

## 2. Install the Android companion

Download `androcall-Android.apk` from the same releases page and open it on the phone.
Android will ask you to allow installing from your file manager — this is normal for an
APK that was not installed from the Play Store.

> androcall is not on the Play Store. It is published as a signed APK so that people can
> install it without a build step, exactly as the brief requires.

## 3. Pair the phone with the Mac

1. On the phone, open **Settings › Bluetooth** and turn Bluetooth on.
2. On the Mac, open **System Settings › Bluetooth**.
3. Select your phone in the list of devices and wait for it to show as *Connected*.
   (If it does not appear, put the phone into pairing mode first — usually by holding
   the Bluetooth button until the indicator flashes.)
4. macOS may ask you to confirm a pairing code on both devices.

## 4. Start the companion

1. Open **androcall** on the phone.
2. Grant the permissions when asked. Each one explains what it is for.
3. Choose a **6-digit pairing code** of your own and enter it.
4. Tap **Start androcall**. A permanent notification appears — that is the foreground
   service that keeps the Mac able to reach the phone. It is expected; Android requires
   a foreground service for this.

## 5. Connect the Mac

1. Launch **androcall** on the Mac.
2. Click **Get started**.
3. Your phone should appear in the list under *Your Android phones*. Click it.
4. Type the same 6-digit code you entered on the phone.
5. **Compare the verification code.** The Mac shows a four-digit code; the companion
   shows the same one. They must match.

   If they do not match, stop: something is intercepting the connection. See
   [`SECURITY.md`](SECURITY.md).

6. Click **The codes match — continue**.

The dashboard then shows the phone's name, its Android version, the battery level and
the current audio route.

## 6. Grant the remaining permissions

The companion needs a few permissions for the full experience:

| Permission | Needed for | If you skip it |
|---|---|---|
| *Phone state* | Noticing incoming calls | You will not see incoming calls on the Mac |
| *Make calls* | Placing calls from the Mac | The Mac opens the phone's dialer instead |
| *Contacts* | Browsing contacts on the Mac | The Mac shows no contacts |
| *Call log* | The recent-calls list | The Mac hides the recent-calls view |
| *Notifications* | The foreground-service notification | The service may be killed by the system |

### Optional: make androcall your default phone app

Android only lets an app answer, decline and end calls when it is the phone's **default
phone app**. On the companion's screen, tap **Set as default phone app** and confirm in
Android's dialog.

This is optional. Everything else works without it; only the answer, decline, end and
mute buttons on the Mac need it.

## 7. Optional: launch at login

**System Settings › General › Login Items** in androcall's Settings tab adds androcall
to the list of apps that start when you log in.

## Privacy in one paragraph

androcall has no account, no server and no analytics. Your contacts, your call history
and your phone numbers travel only between your Mac and your phone, encrypted. The Mac
keeps a copy of the contacts it has synchronised so that the list is available quickly;
you can delete that copy at any time in **Settings › Privacy › Delete local contact
data**.
