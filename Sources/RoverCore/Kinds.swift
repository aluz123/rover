// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation

public enum Kind: UInt8, CaseIterable {
    case other = 0, folder, pdf, image, video, audio, doc, sheet, slides, code, archive, text, app, email

    public var label: String {
        switch self {
        case .other: return "File"
        case .folder: return "Folder"
        case .pdf: return "PDF"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .doc: return "Document"
        case .sheet: return "Spreadsheet"
        case .slides: return "Presentation"
        case .code: return "Code"
        case .archive: return "Archive"
        case .text: return "Text"
        case .app: return "App"
        case .email: return "Email"
        }
    }
}

enum Kinds {
    static let table: [String: Kind] = {
        var t: [String: Kind] = [:]
        func put(_ k: Kind, _ exts: String) { for e in exts.split(separator: " ") { t[String(e)] = k } }
        put(.pdf, "pdf")
        put(.image, "jpg jpeg png gif heic heif webp tiff tif bmp svg raw cr2 cr3 nef arw dng psd ai ico avif")
        put(.video, "mp4 mov m4v avi mkv webm wmv flv mpg mpeg 3gp mts")
        put(.audio, "mp3 m4a wav aiff aif flac aac ogg opus caf alac wma mid midi")
        put(.doc, "doc docx pages rtf odt rtfd tex epub")
        put(.sheet, "xls xlsx xlsm numbers csv tsv ods")
        put(.slides, "ppt pptx key odp")
        put(.code, "swift py js mjs cjs ts tsx jsx java kt c h cc cpp hpp m mm rs go rb php sh zsh bash fish pl lua r sql html htm css scss json yaml yml toml xml ipynb cs scala dart vue svelte gradle makefile dockerfile")
        put(.archive, "zip tar gz tgz bz2 xz 7z rar dmg pkg iso")
        put(.text, "txt md markdown log rst org")
        put(.app, "app")
        put(.email, "eml emlx msg mbox")
        return t
    }()

    /// Packed (up to 8 lowercase bytes) extension -> kind, for allocation-free lookups while indexing.
    static let packed: [UInt64: Kind] = {
        var d: [UInt64: Kind] = [:]
        for (e, k) in table { d[pack(Array(e.utf8))] = k }
        return d
    }()

    static func pack(_ b: [UInt8]) -> UInt64 {
        var v: UInt64 = 0
        for (i, c) in b.prefix(8).enumerated() { v |= UInt64(c) << (8 * UInt64(i)) }
        return v
    }

    static func kind(ofLowName p: UnsafePointer<UInt8>, len: Int) -> Kind {
        var dot = -1
        var i = len - 1
        while i > 0 && len - i <= 10 { if p[i] == UInt8(ascii: ".") { dot = i; break }; i -= 1 }
        if dot < 0 {
            if len == 8 && memcmp(p, "makefile", 8) == 0 { return .code }
            if len == 10 && memcmp(p, "dockerfile", 10) == 0 { return .code }
            return .other
        }
        let n = len - dot - 1
        if n == 0 || n > 8 { return .other }
        var v: UInt64 = 0
        for j in 0..<n { v |= UInt64(p[dot + 1 + j]) << (8 * UInt64(j)) }
        return packed[v] ?? .other
    }

    static func ext(ofLow s: String) -> String {
        guard let d = s.lastIndex(of: "."), d != s.startIndex else { return "" }
        return String(s[s.index(after: d)...])
    }

    /// Directory extensions treated as single files (not descended into).
    static let packages: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "bundle", "framework",
                                        "plugin", "kext", "xcarchive", "logicx", "band", "fcpbundle", "imovielibrary",
                                        "rtfd", "pages", "numbers", "key", "appex", "prefpane", "saver", "qlgenerator",
                                        "photobooth", "aplibrary", "xcodeproj", "xcworkspace", "playground", "lproj"]
}
