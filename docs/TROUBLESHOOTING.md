# Troubleshooting

Every symptom and what actually causes it. The macOS app's **Diagnostics** screen
shows the live state of the connection and a copy of the log.

---

## The phone is not listed

**The companion app is not running.** The GATT server only exists while androcall is
running on the phone. Open it and tap **Start androcall**.

**The phone is not paired with the Mac.** macOS only lets you pair a device from System
Settings. Pair the phone in **System Settings › Bluetooth**, then come back.

**The phone is out of range, or Bluetooth is off on it.** Check the phone's Bluetooth
switch.

**The phone is connected to something else.** A phone that is connected to a headset or
to a car may stop advertising. Disconnect it and try again.

---

## "androcall is not allowed to use Bluetooth"

macOS denied the app Bluetooth access. Grant it in
**System Settings › Privacy & Security › Bluetooth** and restart androcall.

---

## The phone connects but the session never establishes

The Mac shows *Authorising…* and then gives up.

**The two PIN codes do not match.** They must be the same 6 digits. The phone's code is
whatever you typed in the companion app.

**The phone has restarted.** The PIN lives in the companion's memory. Re-enter it and
press **Start androcall** again.

**The Bluetooth link is too weak or too slow.** Move the phone and the Mac closer, and
try again.

---

## The verification codes do not match

**Stop.** This means the handshake was intercepted or the two devices disagree about the
session. See [`SECURITY.md`](SECURITY.md) for what this means.

Common causes that are benign:

- One of the devices was restarted mid-handshake, so the two ends computed different
  codes. Start the pairing again from scratch.
- You typed the PIN on the phone *after* the Mac had already sent its PIN. Enter the
  PIN on the phone first, press **Start androcall**, and only then begin the pairing on
  the Mac.

---

## No contacts appear

1. **Has the companion been allowed to read contacts?** On the phone, open androcall and
   check the permission list. If *Contacts* is denied, the phone answers
   `permission_denied` and the Mac says so in its diagnostics.
2. **Is *Synchronise contacts* switched on?** It is in the Mac's **Settings** tab.
3. **Is there a call in progress?** Contact synchronisation waits until the phone is
   idle.
4. **Try *Sync now*.** The Dashboard's *Sync contacts* button requests a fresh copy.

---

## No incoming calls

This is the most common problem, and it is almost always Android's doing.

**Make sure the companion's foreground notification is showing.** Android killed the
service otherwise. If the notification is missing, the service has been stopped.

**Exempt androcall from battery optimisation.** On the phone:

| Manufacturer | Where |
|---|---|
| Samsung | Settings › Battery › Background usage limits › *androcall* → **Never sleep** |
| Xiaomi / MIUI | Settings › Apps › androcall › Battery saver → **No restrictions**, then turn off *Autostart* restrictions |
| Huawei / EMUI | Settings › Battery › App launch › androcall → everything on, and *Manage manually* |
| Oppo / ColorOS | Settings › Battery › App battery management › androcall → **Allow background activity** and *Allow foreground* |
| Vivo | Settings › Battery › Background power management › androcall → **Unrestricted** |
| OnePlus | Settings › Battery › Battery optimisation › androcall → **Do not optimise** |
| Pixel / stock Android | Settings › Apps › androcall › Battery › **Unrestricted** |

**Check that the phone is not in a battery-saver mode.** Battery saver is a good way to
save power and a good way to miss calls.

**Keep the companion's notification enabled.** Its foreground service is what Android
requires; hiding the notification is what gets the service killed.

---

## Answer and End are greyed out

Android only lets an app answer, decline and end calls when that app is the phone's
**default phone app**. This is an Android rule, not a bug in androcall.

On the phone, tap **Set as default phone app** in the companion, and confirm in
Android's dialog. Until then, androcall shows the call on the Mac and the phone rings
normally — you just have to answer it on the phone.

---

## I can see the call but I cannot hear anything on the Mac

**Call audio stays on the phone.** The phone is the Bluetooth handset; the call's audio
goes to the phone's earpiece or to a headset paired with the *phone*. androcall is a
control surface, not an audio device, and it does not capture or redirect call audio.

If you want the call on your Mac, pair your Mac's Bluetooth headset with the **phone**,
not with the Mac.

---

## The app will not open ("damaged")

The current builds are ad-hoc signed rather than notarised. Open the app with
**right-click › Open**, or:

```bash
xattr -dr com.apple.quarantine /Applications/androcall.app
```

See [`SETUP.md`](SETUP.md).

---

## The Mac app keeps reconnecting

**The phone is sleeping.** A phone that is idle may stop advertising its BLE service.
Keeping the companion's foreground service alive is the best you can do; some OEM
firmware still suspends it.

**Battery.** Plug the phone in while you are using androcall for long sessions.

**Too many devices.** If the phone is connected to a watch or a car, it may only
advertise to one central at a time. Disconnect the other device.

---

## The diagnostic log

**Diagnostics › Diagnostic log** shows the connection lifecycle. It never contains
contact names, numbers, call content or keys — only events.

**Copy log** puts the whole log on the clipboard, which is the easiest way to include it
in a bug report. It also includes the Mac's session log.

---

## Reporting a bug

Please include:

1. Your macOS version (`About This Mac`) and your phone's Android version.
2. The contents of the diagnostic log from both devices.
3. What you expected and what happened instead.
4. Whether the problem happens every time or intermittently.

Open an issue at <https://github.com/JivinSardine/androcall/issues>.
