# Spatial Bee

An iPhone prototype that synthesizes a bee or mosquito and renders it binaurally over
headphones, with the insect's direction set by where the phone is pointing. Phone
orientation only; no headphone head tracking in this version.

## What is in the project

- `SpatialBee/InsectSynth.swift` — additive synthesizer running inside an
  `AVAudioSourceNode` render block. Wingbeat fundamental plus harmonics, a random-walk
  pitch wobble, amplitude flutter, and a little low-passed noise. Takes a Doppler ratio.
- `SpatialBee/SpatialAudioEngine.swift` — the `AVAudioEngine` graph. Mono source into an
  `AVAudioEnvironmentNode` set to the HRTF-HQ rendering algorithm, with inverse-distance
  rolloff tuned for arm's-reach distances and a touch of small-room reverb. Listener at
  the origin facing -z, up +y, right +x.
- `SpatialBee/MotionTracker.swift` — CoreMotion device attitude at 100 Hz in the
  `xArbitraryZVertical` reference frame (gyro and accelerometer, no magnetometer).
  Rotates the chosen pointing axis of the phone into the world frame.
- `SpatialBee/BeeController.swift` — per-frame glue on a `CADisplayLink`. Converts the
  world pointing vector into the listener frame using a stored forward yaw, scales it to
  the chosen radius, adds a small random-walk wobble, derives Doppler from radial
  velocity, and pushes the position to the engine. Falls back to a synthetic orbit when
  Auto-orbit is on or when motion is unavailable (the simulator).
- `SpatialBee/ContentView.swift` — SwiftUI controls and readouts.

## Browser version (no Mac pairing needed)

`docs/index.html` is a self-contained web page that does the same experiment in Safari:
Web Audio `PannerNode` in HRTF mode for the binaural rendering, `DeviceOrientationEvent`
for the phone attitude, a custom periodic wave plus filtered noise for the insect. It is
the route for a managed iPhone that refuses to pair with a Mac. Hosted with GitHub Pages
from the `docs` folder; motion access requires HTTPS and a tap on Start, and on iOS the
ring/silent switch must be on ring for Web Audio to be audible. Auto-orbit works anywhere,
including on a desktop browser, for checking the audio without a phone.

## Running the native app on the phone

1. Open `SpatialBee.xcodeproj` in Xcode, select the SpatialBee target, and set your
   development team under Signing & Capabilities. The bundle identifier is
   `com.spatialbee.prototype`; change it if Xcode complains it is taken.
2. Plug in or pair the phone and run. No permission prompts: device attitude does not
   need motion authorization.
3. Put on headphones. The Status section shows the active output route and warns if it
   is the speaker, where the environment node silently falls back to panning.
4. Tap Start. After a moment, hold the phone pointing straight ahead of your face and
   tap Re-center forward. From then on the insect sits wherever the phone points, at the
   distance set by the slider.

The Pointing axis picker chooses between the top edge of the phone (hold it like a
remote) and the back of the phone (hold it like a camera).

## Things to check on first device run

- Direction sense. If the insect moves opposite to the phone, the attitude matrix is
  being applied in the wrong direction. The one place to change is
  `MotionTracker.rotateToWorld`, where the matrix would need transposing. The simulator
  cannot exercise this, so it is unverified.
- Front-back confusion. With a generic HRTF and no head tracking, sources behind can
  read as in front. Moving the phone through the side resolves it; a static source
  behind the head is the hard case.
- Bluetooth latency. AirPods Pro add roughly 150 to 200 ms between the engine and the
  ear. Slow sweeps feel fine, fast flicks lag. Wired headphones remove this for testing.
- Level. Gain is set conservatively in `InsectSynth.gain`. Raise if quiet.

## Next steps

- Head tracking with `CMHeadphoneMotionManager` on AirPods Pro: feed the earbud attitude
  into `environment.listenerVectorOrientation` so the insect stays fixed in the room
  when you turn your head. Needs the yaw-alignment step described earlier, since the
  earbuds have no magnetometer.
- Replace the synthesizer with recorded samples if realism matters more than control.
- Try `PHASE` instead of the environment node if occlusion or multiple sources come up.
