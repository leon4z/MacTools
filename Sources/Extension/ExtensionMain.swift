import Foundation

@_silgen_name("NSExtensionMain")
func NSExtensionMain(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@main
enum ExtensionMain {
    static func main() {
        exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
    }
}
