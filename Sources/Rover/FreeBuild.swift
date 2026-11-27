// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
// The open-source build of Rover: stand-ins for the closed-source Rover Pro parts (see RoverCore/FreeBuild.swift).
// Pro menu items here open getrover.dev/pro, where the official app is.
import AppKit
import Carbon.HIToolbox
import UserNotifications
import RoverCore

struct Shortcut: Equatable {
    let id: String, label: String, key: Int, mods: Int
    static let standard = Shortcut(id: "opt-space", label: "⌥ Space", key: kVK_Space, mods: optionKey)
    static let all = [standard]
    static var current: Shortcut { standard }
    static func choose(_ s: Shortcut) {}
}

enum Checkup {
    static let threshold: Int64 = 1 << 30
    static var foundBytes: Int64 { 0 }
    static var enabled: Bool { false }
    static func start() {}
    static func setEnabled(_ on: Bool) {}
    static func runIfDue(force: Bool = false, done: ((Int64) -> Void)? = nil) {}
}

final class NotificationOpener: NSObject, UNUserNotificationCenterDelegate { static let shared = NotificationOpener() }

final class ProWindow {
    static let shared = ProWindow()
    var isVisible: Bool { false }
    func show(key: String? = nil) { NSWorkspace.shared.open(License.buyURL) }
}

enum ProJobs {
    static func start() {}
    static var imageStatus: String { "" }
}

struct Person: Identifiable, Hashable { var id: String { email }; let name: String; let email: String }
struct Offer: Identifiable, Equatable { let id: String, fromName: String, name: String, bytes: Int64; var status: String }

final class Account {
    static let shared = Account()
    var signedIn: Bool { false }
    var email: String? { nil }
    var deviceID: String? { nil }
    var error: String { "" }
    func registerDevice() {}
    func signIn() { ProWindow.shared.show() }
    func signOut() {}
}

final class Inbox {
    static let shared = Inbox()
    var offers: [Offer] { [] }
    func start() {}
    func poll() {}
    func accept(_ o: Offer) {}
}

final class People {
    static let shared = People()
    var google: [Person] { [] }
    func load() {}
    func refreshGoogle() { ProWindow.shared.show() }
}

final class Transfers {
    static let shared = Transfers()
    static var headless = false
    static func ticket(in text: String) -> String? { nil }
    func receive(_ text: String, from: String? = nil) { ProWindow.shared.show() }
    func stopAll() {}
}

final class ShareWindow {
    static let shared = ShareWindow()
    var isVisible: Bool { false }
    func show(_ paths: [String]) { ProWindow.shared.show() }
}

final class TransfersWindow {
    static let shared = TransfersWindow()
    var isVisible: Bool { false }
    func show() { ProWindow.shared.show() }
}

final class ServiceProvider: NSObject {
    @objc func sendWithRover(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        DispatchQueue.main.async { ProWindow.shared.show() }
    }
}

enum ProCLI {
    static let commands: Set<String> = ["signin", "inbox", "accept", "send", "receive", "pro", "images", "drives", "--render-pro"]
    static func run(_ args: [String], _ e: Engine) {
        guard let c = args.first, commands.contains(c) else { return }
        print("“rover \(c)” is part of Rover Pro, in the official app from getrover.dev/pro.")
        exit(1)
    }
}
