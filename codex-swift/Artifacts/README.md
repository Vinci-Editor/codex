`CodexMobileCore.xcframework` is generated, not hand-authored.

Run:

```sh
./scripts/build-mobile-xcframework.sh
```

The Swift package automatically consumes `Artifacts/CodexMobileCore.xcframework`
when it exists. Without the artifact, `CodexKit` builds against the source
fallback bridge so package-level Swift tests can still run on a checkout that
does not have the Rust iOS targets installed.
