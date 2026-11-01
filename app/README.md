# Museek for iPhone

Museek is a fully native SwiftUI client for the private Museek music server. It uses AVFoundation for playback, MediaPlayer for lock-screen controls, Keychain for the device session, and the application-support directory for downloaded originals.

Open `Museek.xcodeproj` in Xcode, or build from the command line:

```sh
xcodegen generate
xcodebuild -project Museek.xcodeproj -scheme Museek -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The checked-in Xcode project is generated from `project.yml`. Run `xcodegen generate` after changing the project definition. The server address must use HTTPS except for loopback development addresses.
