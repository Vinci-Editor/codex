# CodexMobileDemo

Minimal iOS 26 demo app source for embedding `CodexKit`.

This folder intentionally keeps the app narrow:

- ChatGPT device-code sign-in
- provider selection
- workspace selection
- streaming chat
- built-in tool transcript
- one custom Swift tool

Generate and run the sample project with:

```sh
xcodegen generate
xcodebuild -project CodexMobileDemo.xcodeproj -scheme CodexMobileDemo -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4'
```

For LM Studio on the simulator, `http://127.0.0.1:1234/v1` can work. On a
physical iPhone, use the Mac's LAN URL and enable local-network and development
ATS exceptions in the app target.
