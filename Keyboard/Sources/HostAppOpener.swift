import UIKit

/// Opens the containing app from the keyboard extension.
///
/// `UIApplication.shared` is unavailable in extensions, but the application object is on the
/// responder chain. `open(_:options:completionHandler:)` is not extension-unavailable in the
/// iOS 26 SDK (`openURL:` stopped working in iOS 18). Requires Full Access on iOS 26.
@MainActor
enum HostAppOpener {
    static func open(_ url: URL, from responder: UIResponder, completion: ((Bool) -> Void)? = nil) {
        var current: UIResponder? = responder
        while let candidate = current {
            if let application = candidate as? UIApplication {
                application.open(url, options: [:]) { success in
                    completion?(success)
                }
                return
            }
            current = candidate.next
        }
        completion?(false)
    }
}
