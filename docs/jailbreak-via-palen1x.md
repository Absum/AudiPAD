# Jailbreaking the iPad via palen1x (Windows PC)

This is the runbook for jailbreaking `iPad6,4` (iPad Pro 9.7" 2016, A9X) on iOS 16.7.14 using **palen1x** — a bootable Linux image that runs palera1n natively.

## Why this path

The development Mac is on macOS Tahoe (26.x) with Apple Silicon (M4). palera1n's pongoOS payload-upload phase fails consistently on this combination (checkm8 fires correctly, but the subsequent USB transfer hangs and the iPad falls back to normal boot). Booting the Windows PC into Linux from a USB stick sidesteps the macOS USB stack entirely.

## Prereqs

- **iPad** — `iPad6,4`, currently on iOS 16.7.14, charged, with the **Apple original Lightning cable** that came with it
- **Windows PC** — any reasonably modern one with USB ports and a BIOS/UEFI you can enter at boot
- **USB stick** — 8 GB or larger, will be erased
- **Rufus** — free Windows tool for flashing ISOs (https://rufus.ie)
- **palen1x ISO** — from https://github.com/palera1n/palen1x/releases (latest `palen1x-x86_64-*.iso`)
- ~30 minutes for the first run; <5 minutes for subsequent re-jailbreaks

## One-time setup (Windows side)

1. **Download palen1x** — grab the latest `palen1x-x86_64-*.iso` from the GitHub releases page.
2. **Download Rufus** from rufus.ie. Run it (it's portable, no install needed).
3. **Plug in the USB stick.** Anything on it will be wiped.
4. In Rufus:
   - **Device**: pick your USB stick
   - **Boot selection**: click `SELECT` → choose the palen1x ISO
   - **Partition scheme**: GPT (or MBR if the PC is older BIOS-only)
   - **Target system**: UEFI (or BIOS to match)
   - Leave everything else default
   - Click **START**. If asked about ISO/DD mode → pick **DD mode** (image mode).
   - Wait for flash to complete (~2 min).
5. Eject the stick safely.

## Booting palen1x

1. Plug the USB stick into the **Windows PC**. Leave the iPad disconnected for now.
2. Restart the PC and enter the **boot menu**:
   - Common keys: `F12`, `F11`, `F10`, `Esc`, `F2`, `Del` (depends on the PC manufacturer — Dell often `F12`, HP often `F9`, Lenovo often `F12` or `Enter` + `F12`, ASUS often `F8` or `Esc`)
   - Hit the key repeatedly the instant the manufacturer logo appears
3. From the boot menu, pick the **USB stick** (often shown as the stick's brand name).
4. palen1x boots into a minimal Linux + palera1n menu. No need to touch anything Linux-side.

## Running palera1n (from the palen1x menu)

The palen1x UI walks you through the steps. Outline:

1. **Connect the iPad** to the Windows PC with the Apple Lightning cable now.
2. From the palen1x main menu, pick **"palera1n (rootful)"** — equivalent to `palera1n -cf` (set up fakefs + boot it). First-time setup; subsequent re-jailbreaks use `palera1n -f` (fast boot from existing fakefs).
3. palen1x will:
   - Detect the iPad in normal mode
   - Put it into Recovery (you'll see iTunes/cable logo on the iPad)
   - Prompt for **DFU mode** with a live countdown

### DFU mode procedure (iPad Pro 9.7")

This is the timing-critical step. Get your fingers in position **before** you press Enter:
1. **Thumb on Power** (top-right corner), **index on Home** (bottom front). Don't press yet.
2. Press Enter when palen1x prompts.
3. The moment the first countdown appears, press **both buttons hard and hold**.
4. When palen1x prompts to release Power (second countdown phase appears), **release Power only**. **Keep holding Home firmly.**
5. Hold through the entire second countdown.
6. **Watch the iPad screen** — it must go **completely black** (no logo, no cable, just black). Black = DFU mode achieved.

Multiple attempts are normal. If you keep getting "did not enter DFU", relax and try again — the timing is consistent once you get the rhythm.

### After DFU is reached

palen1x runs checkm8 (a few seconds), uploads pongoOS, applies kernel patches, and reboots the iPad into the jailbroken state. Expected timeline:

```
[detect DFU]            ~1–2 sec
[checkm8]               ~5 sec
[pongoOS upload]        ~10 sec
[kernel patches]        ~10 sec
[device reboots]        ~30 sec
[jailbroken boot]       ~20 sec
```

When complete, the iPad shows the iOS Home screen with a new **"palera1n" loader app icon**. Open it to install Sileo/Zebra bootstrap.

## After the first successful jailbreak

1. **Change the root password.** Default is `alpine`. From SSH (`iproxy 2222 22 &` then `ssh root@localhost -p 2222`, or use a tool inside the iPad), run `passwd`. Save the new password somewhere persistent (`docs/secrets/` is gitignored if we need to track it).
2. **Pull the USB stick** out of the Windows PC, reboot back into Windows. The iPad stays jailbroken until its next full reboot.

## Subsequent re-jailbreaks (after a deep reboot)

When the iPad goes through a full reboot (battery dead, manual reboot, kernel panic), the jailbreak is gone and you'll need palen1x again. Procedure shortens to:

1. Plug the USB stick into the Windows PC. Boot from it (same as above).
2. Connect iPad, pick **"palera1n (fast — boot fakefs)"** from the menu (`palera1n -f`) — skips the fakefs-setup step.
3. Same DFU procedure.
4. Total recovery: ~5 minutes.

The `/Applications/AudiPad.app/` directory persists on disk through unjailbreak — after re-jailbreaking, run `uicache -p /Applications/AudiPad.app` via SSH if the icon is missing from the Home screen. See [[audipad-jailbreak-semi-tether-risk]] for the full degradation model.

## Troubleshooting

**"checkm8 failed"** — checkm8 has a ~50% per-attempt success rate on some USB configurations. Just retry. If it fails 5+ times in a row, swap to a different USB port on the PC (USB-A preferred over USB-C if the PC has both).

**"Whoops, device did not enter DFU mode"** — your buttons weren't held continuously. Try again with firmer pressure and start holding the buttons *before* pressing Enter. The iPad Pro 9.7" Home button can wear with age; if mushy/unresponsive in Settings, that's the real culprit and the buttons-based DFU may not work cleanly.

**iPad doesn't appear at all** — try a different cable (must be data-capable, not charge-only), different USB port. If still no luck, on the PC the device should show in `lsusb` as Apple Inc. when in normal mode and as `Apple, Inc. Mobile Device (DFU Mode)` when DFU is reached.

**palen1x doesn't boot from USB** — BIOS likely has Secure Boot enabled. Enter BIOS Setup at boot and either disable Secure Boot temporarily, or set boot order to prioritize USB. Re-enable Secure Boot after you're done if you care about it.

**iPad boots into normal iOS instead of jailbroken state** — pongoOS upload failed mid-transfer (same symptom we hit on the Mac). Less common on Linux but possible. Retry — fresh attempt usually succeeds.

## Related project context

- Decision: "Use palera1n for the AudiPad jailbreak" — why palera1n in the first place
- Decision: "Skip iOS 16.6.1 downgrade — stay on 16.7.14, jailbreak-side app install" — why we're not on TrollStore
- Memory: `audipad-jailbreak-plan-current` — the M1 jailbreak + app install plan end-to-end
- Memory: `audipad-jailbreak-semi-tether-risk` — what happens after a deep reboot, mitigation model
