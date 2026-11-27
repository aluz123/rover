// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
// The open-source build of Rover. Rover Pro (sending files, image text search, unplugged drives, pins and more)
// is closed source and ships only in the official app from getrover.dev; these stand-ins keep this build compiling
// and show where Pro would appear. scripts/build.sh leaves this file out when the Pro sources are present.
import Foundation

public enum License {
    public static let buyURL = URL(string: "https://getrover.dev/pro")!
    public static let manageURL = URL(string: "https://getrover.dev/pro/manage")!
    public static let price = "$2.95"
    public static let priceLong = "$2.95 for the first month, then $9.95 a month"
    public struct Info: Equatable { public let kind: String; public let id: String; public let expires: Date?; public var valid: Bool { false } }
    public enum RenewResult: Equatable { case notNeeded, renewed, ended, failed(String) }
    public static let changed = Notification.Name("RoverLicenseChanged")
    public static var isPro: Bool { false }
    public static var storedKey: String? { nil }
    public static var info: Info? { nil }
    public static func verify(_ raw: String) -> Bool { false }
    @discardableResult public static func activate(_ raw: String) -> Bool { false }
    public static func deactivate() {}
    public static func renewIfNeeded(within: TimeInterval = 0, force: Bool = false, base: String? = nil, completion: @escaping (RenewResult) -> Void) { completion(.notNeeded) }
}

public enum Pins {
    public static var all: [String] { [] }
    public static func contains(_ p: String) -> Bool { false }
    @discardableResult public static func toggle(_ p: String) -> Bool { false }
}

public final class ImageIndex {
    public static let shared = ImageIndex()
    public private(set) var progress = (done: 0, total: 0)
    public var count: Int { 0 }
    public var isRunning: Bool { false }
    public func refresh(completion: (() -> Void)? = nil) { completion?() }
    public func hits(for q: ParsedQuery, excluding: Set<String>, limit: Int = 30) -> [Hit] { [] }
    public func entry(_ path: String) -> (text: String, labels: [String])? { nil }
}

public final class DriveCatalog {
    public static let shared = DriveCatalog()
    public struct Drive: Hashable {
        public let uuid: String
        public var name: String, count: Int, bytes: Int64, cataloged: Double
        public var mountPath: String { "/Volumes/" + name }
        public var isConnected: Bool { false }
    }
    public var onChange: (() -> Void)?
    public var all: [Drive] { [] }
    public func isCataloging(_ uuid: String) -> Bool { false }
    public static func mountedExternal() -> [(path: String, name: String, uuid: String)] { [] }
    public func refresh(maxAge: Double = 0, force: Bool = false) {}
    public func catalog(path root: String, name: String, uuid: String) {}
    public func forget(_ uuid: String) {}
    public func hits(for q: ParsedQuery, excluding: Set<String>, limit: Int = 30) -> [Hit] { [] }
}
