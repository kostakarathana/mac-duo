<p align="center"><img src="docs/icon.png" width="128" alt="Mac Duo icon"></p>

<h1 align="center">Mac Duo</h1>

<p align="center">
  Close your MacBook and the screen folds away like iPhone Duo.<br>
  Hold the power button and it fades out with a glossy sheen.<br><br>
  <a href="https://github.com/kostakarathana/mac-duo/releases/latest/download/MacDuo.dmg"><b>Download for Mac</b></a> ·
  <a href="https://kostakarathana.github.io/mac-duo/">Website</a>
</p>

<p align="center"><img src="docs/frames/fold/frame_012.jpg" width="640" alt="The desktop folding into the hinge"></p>

## What it does

- **Lid fold.** As the lid closes, your desktop tilts into the hinge. It stays sharp at the hinge, frosts over toward the top edge, dims and disappears. The animation follows the real hinge angle at 60 Hz, so it moves with your hand and reverses if you open the lid again.
- **Readjustments are ignored.** A fold only starts when the lid is **below 55°**, **closing faster than 45°/s**, and has **dropped at least 25°** in the last 1.5 s. A slow, steady close below 32° also counts. If you stop halfway, the fold reverses after a second. You can pick Relaxed, Normal or Strict detection from the menu.
- **Glossy power-off fade.** Holding the power button (1.2 s by default) plays a specular sweep: the screen frosts, recedes like a pane of glass and fades to black. A quick tap (lock/sleep) does nothing. It also plays on menu-bar Shut Down and Restart.

## Install

1. Download [`MacDuo.dmg`](https://github.com/kostakarathana/mac-duo/releases/latest/download/MacDuo.dmg) and drag **Mac Duo** to Applications.
2. Open it. The app is ad-hoc signed, not notarized, so macOS will block it the first time. Go to **System Settings → Privacy & Security → Open Anyway**, or run:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Mac Duo.app"
   ```
3. Grant the optional permissions when asked:
   - **Screen Recording**: lets the fold show your real desktop. One frame is kept in memory and never saved. Without it you get a frosted blur instead.
   - **Input Monitoring**: lets the app see the power button.

Requires macOS 14 or later. The lid fold needs a MacBook with a lid angle sensor, which covers most Apple silicon MacBooks and the 2019 16" MacBook Pro.

## Build from source

You only need the Xcode Command Line Tools:

```sh
./scripts/build.sh 1.0.0      # runs tests, builds a universal app, packages build/MacDuo.dmg
```

Developer commands:

```sh
MacDuo --trace 10                               # live hinge angle + detector state
MacDuo --simulate close|cancel|adjust|reopen    # scripted lid motion through the real app
MacDuo --demo fold|fade                         # play an animation once
MacDuo --render fold|fade desk.png out/ 30      # render frames offscreen
```

### Layout

| Path | What it is |
| --- | --- |
| `Sources/Core/CloseDetector.swift` | Lid state machine that tells a close from an adjustment (pure, tested) |
| `Sources/Core/PowerHold.swift` | Power-button hold detector, easing, per-frame animation parameters |
| `Sources/App/LidSensor.swift` | Reads the hinge angle from the SPU HID sensor (no permission needed) |
| `Sources/App/PowerButtonMonitor.swift` | Power key via event tap + consumer-control HID |
| `Sources/App/DuoOverlay.swift` | Overlay window and the Core Animation layer stack |
| `Sources/App/AppDelegate.swift` | Menu bar app, settings, sleep/wake and shutdown handling |
| `Tests/main.swift` | 24 scenario tests: real closes, slams, slow closes, readjustments, wobbles, change of mind |
| `docs/` | The GitHub Pages website |

## License

MIT. This is an independent fan project, not affiliated with Apple.
