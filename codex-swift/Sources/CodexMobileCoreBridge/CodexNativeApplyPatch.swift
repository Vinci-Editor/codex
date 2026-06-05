import Foundation

#if os(macOS)
extension CodexMobileCoreBridge {
    static func nativeApplyPatch(_ input: [String: Any]) -> [String: Any] {
        NativeApplyPatch.run(input)
    }
}

private enum NativeApplyPatch {
    static func run(_ input: [String: Any]) -> [String: Any] {
        CodexNativeApplyPatch.run(input)
    }
}
#endif
