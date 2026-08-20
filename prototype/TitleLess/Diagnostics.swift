import Foundation

/// Diagnostic logging, and only in debug builds.
///
/// A shipped browser must not narrate itself. Several of these lines carry the
/// address of the page being loaded, retried or blocked, and `print` in a
/// release build writes to stdout where the device log keeps it — readable by
/// anything that collects a sysdiagnose. None of it leaves the phone, so this
/// is not a policy problem; it is simply the wrong place for a record of
/// somebody's browsing to exist at all in an app that says it keeps none.
///
/// `@autoclosure` is what makes the release build free rather than merely
/// quiet: the message is never constructed, so the string interpolation and
/// every `\(url)` inside it are not evaluated either.
@inline(__always)
func log(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
