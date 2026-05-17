# AudiPad

Custom iPad-based dashboard for a 2013 Audi SQ5. An old iPad Pro 9.7" is jailbroken with palera1n and runs a SwiftUI app that talks to the car over Bluetooth (ELM327 / OBD-II / VAG-UDS), recognizes traffic signs from the rear camera via on-device CoreML, runs navigation, and controls media. Designed for permanent install with power tied to the car's ignition.

## Hardware

- **Vehicle:** 2013 Audi SQ5 (EU, 3.0 TDI biturbo)
- **Compute:** iPad Pro 9.7" 2016 (`iPad6,4`, Apple A9X) — iOS 16.7.14
- **Vehicle bus:** ELM327 Bluetooth OBD-II adapter
- **Power:** switched-12V → 5V DC-DC step-down to the iPad's Lightning port

## Architecture

| Layer | Role |
| --- | --- |
| iOS app (`AudiPad.app`) | SwiftUI dashboard — gauges, map, media, CV overlay |
| Vehicle data | OBD-II + VAG-UDS PIDs over ELM327 BT, surfaced as an `AsyncStream` |
| Vision | `AVCaptureSession` → CoreML traffic-sign model |
| System layer (jailbreak) | launchd daemon for wake-on-charge + kiosk enforcement |

## Repo layout

This repo is being set up. The Xcode project, daemon source, design assets, and docs will land here as the bench MVP comes together.

- `downloads/` — third-party tools and the iOS IPSW used for bench setup; **not tracked**.

## Status

Pre-MVP. Currently on bench: jailbreak + app shell.
