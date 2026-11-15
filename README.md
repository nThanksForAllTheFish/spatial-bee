# Spatial Bee / Jedi Training

An iPhone app in two modes. Explore synthesizes a bee or mosquito and renders it
binaurally over headphones, with the insect's direction set by where the phone is
pointing. Training recreates the Millennium Falcon scene: a remote flies itself around
your head, hovers, charges and fires, and the phone is the saber. AirPods head tracking
keeps the remote fixed in the room as you turn.

## Training mode

`SpatialBee/TrainingGame.swift` is the state machine: patrol (slerp between random
directions on a sphere at a configured angular speed), hover (random length), charge (a
rising tone for the configured warning time), fire, resolve. A bolt is blocked when the
angle between the phone's pointing direction and the remote's direction is inside the
block cone at the moment of fire. Each shot records blocked or hit, the reaction time from
the charge cue to the saber first entering the cone, and the angular error at fire.

Sounds are synthesized (`RemoteSynth.swift`, `OneShots`): the remote's fluttering whine
with a whoosh that follows its angular speed and a charge tone; a bolt from the remote's
position; a saber clash at the saber's position on a block; a stun buzz close to the head
on a hit. `Haptics.swift` adds a sharp tap for a block and a half-second rumble for a hit.
The saber is two sources along the pointing direction: a low hilt hum close to the hand
and a tip (`SaberTipSynth.swift`) a blade length out carrying the hum's upper harmonics,
a crackling fizz in the pinna band, and a swing whoosh with a pitch lift that follows
the blade's angular speed. The clash plays at the tip. Blast shield blanks the screen; double-tap lifts it.

Difficulty lives in `config.json` under `training`: remote speed, hover range, charge
warning, block cone, bolts per round, elevation band. The Tuning section exposes charge
warning, block cone and remote speed as live sliders in Training mode.

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

## Tuning without a rebuild

`docs/config.json` holds every sound parameter that is a number: renderer, gain, reverb,
distance model, wobble, a high-shelf tilt, and per-species fundamental, harmonic count and
rolloff, noise level and cutoff, pitch wander. Both the native app and the web page fetch it
at start and on Reload. Edit the file, push, wait about a minute for Pages, tap Reload. The
native app's Tuning section edits the same values live with sliders; Reset returns to the
last loaded file. Unknown keys are ignored and missing keys fall back to built-in defaults,
so the file can be partial.

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

- Direction sense. Verified on an iPhone 2026-11-14 after transposing the attitude
  matrix in `MotionTracker.rotateToWorld`; the untransposed form mirrored azimuth.
- Front-back confusion. With a generic HRTF and no head tracking, sources behind can
  read as in front. Moving the phone through the side resolves it; a static source
  behind the head is the hard case.
- Bluetooth latency. AirPods Pro add roughly 150 to 200 ms between the engine and the
  ear. Slow sweeps feel fine, fast flicks lag. Wired headphones remove this for testing.
- Level. Gain is set conservatively in `InsectSynth.gain`. Raise if quiet.

## Head tracking

`SpatialBee/HeadTracker.swift` reads AirPods attitude through `CMHeadphoneMotionManager`.
Because the earbuds' reference yaw is arbitrary and drifts, the app never uses absolute
head orientation. Re-center snapshots the head attitude at the same instant it captures
the phone's forward direction; afterwards only the rotation since that snapshot drives
`listenerVectorOrientation`, while the insect's position stays in the aligned frame. The
result is a source that holds still in the room when the head turns, which is the cue
that resolves front-back confusion. Toggle it in Control; the Status section shows the
sample rate. The frame convention was verified on AirPods Pro on 2026-11-14.

## Next steps

- Replace the synthesizer with recorded samples if realism matters more than control.
- Try `PHASE` instead of the environment node if occlusion or multiple sources come up.
