# Getting Spatial Bee onto the iPhone through TestFlight

TestFlight installs over the air from App Store Connect. No Mac pairing, no Developer
Mode, so it works on a managed phone as long as the App Store itself is allowed.

## One-time setup (you)

1. Enroll in the Apple Developer Program at https://developer.apple.com/programs/enroll/
   with a personal Apple ID, not the Seagate one. It costs 99 USD per year and approval
   usually takes one to two days. You get an email when it is active.
2. Install the TestFlight app on the iPhone from the App Store.
3. In Xcode, open Xcode menu, Settings, Accounts, and add the same Apple ID. Once the
   membership is active the account shows a team named after you with role Agent.

## Prepare the project (once the membership is active)

4. Open `SpatialBee.xcodeproj`, click the blue project icon, pick the SpatialBee target
   under TARGETS, then the Signing & Capabilities tab. Tick Automatically manage signing
   and pick your team. Xcode registers the bundle identifier `com.spatialbee.prototype`
   with your account. If it says the identifier is taken, change it to something unique
   such as `com.<yourname>.spatialbee` and note the new value for step 6.

## Create the App Store Connect record (once)

5. Go to https://appstoreconnect.apple.com, Apps, the plus button, New App.
6. Platform iOS, name "Spatial Bee", primary language English, bundle ID the one from
   step 4, SKU anything such as `spatialbee`, full access. Create. Nothing else on the
   app page needs filling in for TestFlight internal testing.

## Upload a build (every time)

7. In Xcode set the run destination to "Any iOS Device (arm64)". Product, Archive.
   Wait for the Organizer window to open with the new archive selected.
8. Click Distribute App, choose App Store Connect, then Upload. Accept the defaults
   (upload symbols, manage version and build number). Click Upload and wait for
   "Upload Successful".
9. App Store Connect processes the build in five to thirty minutes. You get an email.
   The project already declares that it uses no non-exempt encryption, so no export
   compliance question appears.

## Install on the phone

10. In App Store Connect, open the app, TestFlight tab. Under Internal Testing click the
    plus and create a group, for example "Me". Add yourself as a tester. Tick "Enable
    automatic distribution" so every new build goes to the group.
11. The TestFlight app on the phone shows Spatial Bee within a minute. Tap Install.
12. Later builds: repeat steps 7 and 8. Xcode bumps the build number for you. TestFlight
    shows an Update button on the phone.

## If something refuses

- "Missing required icon file": the asset catalog is missing from the target. It is in
  `SpatialBee/Assets.xcassets` and set as the app icon in build settings; check the
  target still lists it.
- "Invalid bundle ID": step 6 and step 4 disagree. Make them match.
- The phone's TestFlight app shows nothing: give it a few minutes after the build is
  marked Ready to Test, and make sure the tester email is the Apple ID signed in on
  the phone, not the Seagate address.
- The App Store is blocked on the phone: TestFlight is blocked too, and the browser
  version at https://nthanksforallthefish.github.io/spatial-bee/ is the fallback.
