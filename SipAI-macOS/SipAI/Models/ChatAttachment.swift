// ChatAttachment.swift
// A file staged for the next chat message: what it is, what the model
// actually receives, and why a file was refused.
//
// Attachments reach a provider two different ways, and the split is not
// cosmetic:
//
//   * TEXT — source, markdown, csv, plain text — is INLINED into the
//     outgoing message. It is therefore stored in the chat file and is
//     re-sent as ordinary history on every later turn, so a follow-up
//     question about the file still works.
//   * IMAGES and PDFs are CONTENT BLOCKS on the one request that
//     carries them. Nothing about them is stored, so the model sees
//     them on that turn only. Storing them would mean a second on-disk
//     format the CLI cannot read, and re-sending an image on every turn
//     multiplies the bill for a picture the user mentioned once.
//
// `ChatMessage.files` records the names either way — that key is the
// shared format both apps read, and it is the only trace an image
// leaves.
//
// A file is loaded, decoded and measured at the moment it is ATTACHED,
// never at send. A refusal the user reads while picking is a choice;
// the same refusal at send is a send that failed.

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// How an attachment is delivered to the model.
enum AttachmentKind: Hashable {
    /// Base64 image. `mediaType` is what the provider is told it is, and
    /// is always one of the four every provider accepts.
    case image(mediaType: String)
    /// A PDF. Sent whole to providers that take one natively; sent as
    /// its extracted text layer to the rest.
    case pdf
    /// Read as text and inlined into the message body.
    case text
}

/// Ceilings, each set by the tightest provider rather than by taste.
enum AttachmentLimits {
    /// Long edge an image is resized down to. Providers downscale above
    /// roughly this themselves and bill for the pixels either way, so
    /// sending more costs money and buys nothing.
    static let imageMaxEdge = 1568

    /// Per-image ceiling on the encoded bytes; Anthropic refuses above
    /// 5 MB. An image over it is re-encoded until it fits.
    static let imageMaxBytes = 5 * 1024 * 1024

    /// Ceiling on the pixels (width × height) a staged image may decode
    /// to. The byte ceilings cannot stand in for it: a few hundred KB
    /// of PNG can declare 60000×60000 and decompress to ~14 GB. Read
    /// off the HEADER and refused before any decode.
    static let imageMaxPixels = 80_000_000

    /// Ceiling on the bytes read at all for an image file. Generous —
    /// an original is legitimately larger than what is sent, since
    /// oversized ones are resized on the way in — but bounded, so a
    /// disk image wearing a picture's extension is never read whole.
    static let imageReadMaxBytes = 128 * 1024 * 1024

    /// A PDF is sent whole. 32 MB is the smallest request ceiling among
    /// the providers that accept one.
    static let pdfMaxBytes = 32 * 1024 * 1024

    /// Ceiling on the bytes read for a text file. Inlined text keeps at
    /// most `textCharLimit` characters, so past this the file is
    /// refused up front rather than decoded whole and then cut — the
    /// whole-file UTF-8 decode is where a multi-GB log used to go.
    static let textMaxBytes = 16 * 1024 * 1024

    /// Page ceiling for a natively-sent PDF on a 200k-context model.
    static let pdfMaxPages = 100

    /// Inlined text is TRUNCATED at this, not refused: an over-long
    /// log is still worth reading the head of, and refusing it leaves
    /// the user nothing. Tighter than the PDF ceiling on purpose — an
    /// inlined text FILE is stored in the chat and re-sent as history
    /// on every later turn, so its length is paid for again on every
    /// question, where a PDF's text rides one request and is gone.
    /// ~200k characters ≈ 50k tokens.
    static let textCharLimit = 200_000

    /// Ceiling on the text extracted from a PDF. Generous, because it
    /// is billed ONCE: the extraction is a per-request content block,
    /// never stored. Sized so a full journal article travels whole —
    /// a measured 32-page Econometrica paper extracts ~82k characters,
    /// and the old shared 50k ceiling silently dropped its second
    /// half, conclusion included. ~400k characters ≈ 100k tokens.
    static let pdfTextCharLimit = 400_000

    /// Per-message cap. Guards the request size and the composer's own
    /// layout; nobody attaches twenty files by accident.
    static let maxPerMessage = 20
}

/// Why a file could not be staged. Every case names the file, because
/// these arrive in a batch and "unsupported file type" alone does not
/// say which of five dropped files it means.
enum AttachmentError: LocalizedError {
    case unreadable(name: String)
    case unsupported(name: String, ext: String)
    case tooLarge(name: String, limitBytes: Int)
    case tooManyPixels(name: String)
    case tooManyPages(name: String, pages: Int)
    case noText(name: String)
    case tooMany

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return String(localized: "\(name) could not be read.",
                          comment: "Attachment refused: the file could not be opened or decoded")
        case .unsupported(let name, let ext):
            let kind = ext.isEmpty
                ? String(localized: "that kind of file",
                         comment: "Stand-in for a file extension when a file has none")
                : ".\(ext)"
            return String(localized: "\(name) — \(kind) is not supported. Attach an image, a PDF, or a text file.",
                          comment: "Attachment refused: unsupported file type")
        case .tooLarge(let name, let limitBytes):
            return String(localized: "\(name) is too large (over \(limitBytes / 1_048_576) MB).",
                          comment: "Attachment refused: file exceeds the size ceiling")
        case .tooManyPixels(let name):
            return String(localized: "\(name) has too many pixels to process (over \(AttachmentLimits.imageMaxPixels / 1_000_000) megapixels).",
                          comment: "Attachment refused: image dimensions exceed the decode ceiling")
        case .tooManyPages(let name, let pages):
            return String(localized: "\(name) has \(pages) pages — the limit is \(AttachmentLimits.pdfMaxPages).",
                          comment: "Attachment refused: PDF has too many pages")
        case .noText(let name):
            return String(localized: "\(name) has no text to read.",
                          comment: "Attachment refused: an empty file, or a scanned PDF with no text layer")
        case .tooMany:
            return String(localized: "Only \(AttachmentLimits.maxPerMessage) files can be attached to one message.",
                          comment: "Attachment refused: per-message count cap")
        }
    }
}

/// One staged file. Immutable: everything the send needs is resolved at
/// load time, so a file edited or deleted between attaching and sending
/// cannot change what was promised on screen.
struct ChatAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let kind: AttachmentKind
    /// Bytes of the payload actually staged — post-resize for an image,
    /// so the chip shows what is really being sent.
    let byteCount: Int
    /// Base64 payload for `.image` and `.pdf`; nil for `.text`.
    let base64: String?
    /// Inlinable text: the file's contents for `.text`, the extracted
    /// text layer for `.pdf`.
    let text: String?
    /// The text was cut at `textCharLimit`.
    let textTruncated: Bool

    /// Human-readable size for the chip.
    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var isText: Bool { if case .text = kind { return true }; return false }
}

// Identity is the id alone. The synthesized conformances would compare
// and hash the whole base64 payload, and a SwiftUI diff over a handful
// of chips must not walk several megabytes per pass.
extension ChatAttachment: Hashable {
    static func == (a: ChatAttachment, b: ChatAttachment) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Loading

extension ChatAttachment {
    /// Media types every provider in the catalog accepts. Anything else
    /// is re-encoded into one of them or refused — an `image/heic` sent
    /// verbatim is a 400 on every one of them.
    private static let imageMediaTypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
    ]

    /// Image formats macOS reads and no provider takes. Re-encoded on
    /// the way in rather than refused: a screenshot pasted out of Photos
    /// is a HEIC, and telling the user to go and convert it is a dead
    /// end they cannot resolve from here.
    private static let transcodableImageExtensions: Set<String> = [
        "heic", "heif", "tif", "tiff", "bmp",
    ]

    /// Extensions macOS has no UTI for but that are plainly text.
    private static let extraTextExtensions: Set<String> = [
        "md", "markdown", "csv", "tsv", "log", "env", "ini", "cfg", "conf",
        "toml", "yml", "yaml", "jsonl", "ndjson", "gitignore", "lock",
    ]

    /// Read `url` and stage it. Throws `AttachmentError` with a sentence
    /// the composer can show verbatim.
    static func load(_ pickedURL: URL) throws -> ChatAttachment {
        // Resolve symlinks FIRST, so the chip, the stored `files` names
        // and the wire all name what is actually read. A link called
        // notes.md pointing somewhere else would otherwise stage that
        // other file under the link's name — and the transcript strips
        // the inlined contents, so nothing later would show it either.
        let url = pickedURL.resolvingSymlinksInPath()
        // A filename may legally contain newlines; the chip, the
        // paperclip row and the comma-joined `files` key are all
        // single-line surfaces.
        let name = url.lastPathComponent
            .components(separatedBy: .newlines).joined(separator: " ")
        let ext = url.pathExtension.lowercased()

        // Refuse an over-ceiling file BEFORE reading a byte, then read
        // WITHOUT mapping. The old mapped read was cheap at any size,
        // but everything after it materialized — a multi-GB log reached
        // the whole-file UTF-8 decode — and a mapped page can SIGBUS
        // under a writer truncating the file mid-read (a still-syncing
        // download). stat first, bounded unmapped read second, closes
        // both.
        let ceiling = readCeiling(ext: ext)
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size > ceiling {
            throw AttachmentError.tooLarge(name: name, limitBytes: ceiling)
        }
        guard let data = try? Data(contentsOf: url) else {
            throw AttachmentError.unreadable(name: name)
        }

        if let media = imageMediaTypes[ext] {
            return try stageImage(data: data, url: url, name: name, declaredMediaType: media)
        }
        if transcodableImageExtensions.contains(ext) {
            return try stageImage(data: data, url: url, name: name, declaredMediaType: nil)
        }
        if ext == "pdf" {
            return try stagePDF(data: data, url: url, name: name)
        }
        if looksTextual(ext: ext, data: data) {
            return try stageText(data: data, url: url, name: name)
        }
        throw AttachmentError.unsupported(name: name, ext: ext)
    }

    /// Bytes `load` is willing to read at all for a file of this
    /// extension, checked against the file's size before the read.
    /// Unknown extensions get the text ceiling: the only way an unknown
    /// file is ever accepted is by sniffing as text.
    private static func readCeiling(ext: String) -> Int {
        if imageMediaTypes[ext] != nil || transcodableImageExtensions.contains(ext) {
            return AttachmentLimits.imageReadMaxBytes
        }
        if ext == "pdf" { return AttachmentLimits.pdfMaxBytes }
        return AttachmentLimits.textMaxBytes
    }

    /// Whether to treat the file as text. The UTI is asked first — that
    /// covers every source language the machine knows — and the bytes
    /// are sniffed only when it answers nothing, so a `.swift` file is
    /// never decided by what happens to be in its first 8 KB.
    private static func looksTextual(ext: String, data: Data) -> Bool {
        if extraTextExtensions.contains(ext) { return true }
        // A DYNAMIC type is macOS saying it has never heard of this
        // extension, not saying the file is binary — it hands back a
        // `dyn.…` identifier that conforms to `public.data` and nothing
        // else. Reading that as a verdict refuses every unrecognised
        // text file on the machine, so it has to fall through to the
        // sniff exactly as a nil would.
        if let type = UTType(filenameExtension: ext), !type.isDynamic {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode)
                || type.conforms(to: .json) || type.conforms(to: .xml)
                || type.conforms(to: .yaml) || type.conforms(to: .propertyList) {
                return true
            }
            // A known type that is not text: a .docx or .zip decides
            // here, without a sniff that would call it binary anyway.
            return false
        }
        return sniffsAsText(data)
    }

    /// No UTI, so look. A NUL byte in the head means binary; otherwise
    /// the head must decode as UTF-8. The trailing bytes are trimmed one
    /// at a time because a multi-byte character can straddle the cut,
    /// and that failure would misfile a perfectly good text file.
    private static func sniffsAsText(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        var head = data.prefix(8192)
        if head.contains(0) { return false }
        for _ in 0...3 {
            if String(data: head, encoding: .utf8) != nil { return true }
            guard head.count > 1 else { return false }
            head = head.dropLast()
        }
        return false
    }

    // MARK: Images

    private static func stageImage(data: Data,
                                   url: URL,
                                   name: String,
                                   declaredMediaType: String?) throws -> ChatAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AttachmentError.unreadable(name: name)
        }
        // Dimensions come off the HEADER, before any decode. The byte
        // ceilings cannot catch a decompression bomb — a small file can
        // declare an enormous canvas, and `CGImageSourceCreateImageAtIndex`
        // on one allocates the whole thing.
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0, w * h > AttachmentLimits.imageMaxPixels {
            throw AttachmentError.tooManyPixels(name: name)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AttachmentError.unreadable(name: name)
        }

        let longEdge = max(image.width, image.height)
        // Pass the original bytes through whenever they are already
        // acceptable. Re-encoding a PNG the provider would have taken
        // as-is costs fidelity for nothing.
        if let media = declaredMediaType,
           longEdge <= AttachmentLimits.imageMaxEdge,
           data.count <= AttachmentLimits.imageMaxBytes {
            return ChatAttachment(url: url, name: name,
                                  kind: .image(mediaType: media),
                                  byteCount: data.count,
                                  base64: data.base64EncodedString(),
                                  text: nil, textTruncated: false)
        }

        guard let encoded = reencode(image, name: name) else {
            throw AttachmentError.unreadable(name: name)
        }
        return ChatAttachment(url: url, name: name,
                              kind: .image(mediaType: encoded.mediaType),
                              byteCount: encoded.data.count,
                              base64: encoded.data.base64EncodedString(),
                              text: nil, textTruncated: false)
    }

    /// Resize to the long-edge ceiling and encode into a format every
    /// provider accepts, shrinking further while the result is still
    /// over the byte ceiling. Transparency decides the container: a PNG
    /// keeps the alpha a JPEG would flatten to black.
    private static func reencode(_ image: CGImage, name: String)
        -> (data: Data, mediaType: String)? {
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            hasAlpha = true
        default:
            hasAlpha = false
        }
        let type: CFString = hasAlpha ? UTType.png.identifier as CFString
                                      : UTType.jpeg.identifier as CFString
        let mediaType = hasAlpha ? "image/png" : "image/jpeg"

        var edge = AttachmentLimits.imageMaxEdge
        var quality = 0.85

        // Bounded: each pass either halves the edge or drops the
        // quality, so a pathological source ends in a refusal rather
        // than a loop.
        for _ in 0..<6 {
            guard let scaled = resize(image, longEdge: edge),
                  let out = encode(scaled, type: type, quality: quality)
            else { return nil }
            if out.count <= AttachmentLimits.imageMaxBytes {
                return (out, mediaType)
            }
            if !hasAlpha && quality > 0.4 {
                quality -= 0.2
            } else {
                edge = max(256, edge / 2)
            }
        }
        return nil
    }

    private static func resize(_ image: CGImage, longEdge: Int) -> CGImage? {
        let current = max(image.width, image.height)
        if current <= longEdge { return image }
        let scale = Double(longEdge) / Double(current)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? image.colorSpace
                ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, type: CFString, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: PDFs

    private static func stagePDF(data: Data, url: URL, name: String) throws -> ChatAttachment {
        // Size BEFORE parse: the ceiling must not cost a full PDFKit
        // pass over a file it is about to refuse. (`load` already
        // refused on the stat; this is the belt for a file that grew
        // between the stat and the read.)
        guard data.count <= AttachmentLimits.pdfMaxBytes else {
            throw AttachmentError.tooLarge(name: name, limitBytes: AttachmentLimits.pdfMaxBytes)
        }
        // A password-protected or corrupt PDF fails here rather than at
        // send, where the provider's own error would name neither the
        // file nor the cause.
        guard let doc = PDFDocument(data: data) else {
            throw AttachmentError.unreadable(name: name)
        }
        guard doc.pageCount <= AttachmentLimits.pdfMaxPages else {
            throw AttachmentError.tooManyPages(name: name, pages: doc.pageCount)
        }

        var parts: [String] = []
        for index in 0..<doc.pageCount {
            if let page = doc.page(at: index), let s = page.string, !s.isEmpty {
                parts.append(s)
            }
        }
        var extracted = parts.joined(separator: "\n\n")
        var truncated = false
        if extracted.count > AttachmentLimits.pdfTextCharLimit {
            extracted = String(extracted.prefix(AttachmentLimits.pdfTextCharLimit))
            truncated = true
        }

        // An empty text layer is fine — a scan still reads perfectly on
        // a provider that takes the PDF natively, and the fallback path
        // simply has nothing to inline.
        return ChatAttachment(url: url, name: name, kind: .pdf,
                              byteCount: data.count,
                              base64: data.base64EncodedString(),
                              text: extracted.isEmpty ? nil : extracted,
                              textTruncated: truncated)
    }

    // MARK: Text

    private static func stageText(data: Data, url: URL, name: String) throws -> ChatAttachment {
        // Belt for the pre-read stat racing a growing file: the decode
        // below is whole-file, so it must never see more than the cap.
        guard data.count <= AttachmentLimits.textMaxBytes else {
            throw AttachmentError.tooLarge(name: name, limitBytes: AttachmentLimits.textMaxBytes)
        }
        guard var content = decodeText(data) else {
            throw AttachmentError.unreadable(name: name)
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachmentError.noText(name: name)
        }
        var truncated = false
        if content.count > AttachmentLimits.textCharLimit {
            content = String(content.prefix(AttachmentLimits.textCharLimit))
            truncated = true
        }
        return ChatAttachment(url: url, name: name, kind: .text,
                              byteCount: data.count, base64: nil,
                              text: content, textTruncated: truncated)
    }

    /// UTF-8, then the encodings a text file on this machine plausibly
    /// carries. A lossy decode is deliberately NOT attempted: mojibake
    /// sent to a model is worse than a refusal the user can act on.
    private static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .isoLatin1),
           !s.unicodeScalars.contains(where: { $0.value == 0 }) {
            return s
        }
        return nil
    }
}

// MARK: - Inlining

extension ChatAttachment {
    /// Opening tag of an inlined block, as written. The strip below
    /// matches this and its closing tag as a PAIR — a bare-tag sweep
    /// would eat a closing angle bracket out of the user's own prose,
    /// which is the trap the agent transcript's local-command reader
    /// already documents.
    private static let openPrefix = "<sipai-attachment name=\""
    private static let closeTag = "</sipai-attachment>"

    /// Wrap a text attachment for inlining into the outgoing message.
    /// The name rides the tag so the model can refer to the file by the
    /// name the user sees on the chip.
    static func inlineBlock(name: String, text: String, truncated: Bool) -> String {
        let escaped = name
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        // The BODY must not be able to speak the wrapper's own tags. A
        // file containing the literal closing tag would end the block
        // early, and everything after it — content the file's author
        // chose — would render as the user's own words. Escaping just
        // the opening bracket breaks the match and is the smallest
        // mutation of the file's text.
        let safeText = text
            .replacingOccurrences(of: closeTag, with: "&lt;" + closeTag.dropFirst())
            .replacingOccurrences(of: openPrefix, with: "&lt;" + openPrefix.dropFirst())
        let mark = truncated ? " truncated=\"true\"" : ""
        return "\(openPrefix)\(escaped)\"\(mark)>\n\(safeText)\n\(closeTag)"
    }

    /// What the transcript DRAWS in place of an inlined block: nothing.
    /// The paperclip line under the bubble already names the files, and
    /// a 50k-character dump inside a message bubble is a wall the reader
    /// has to scroll past to reach their own question.
    ///
    /// The stored message keeps the block — that is what makes a
    /// follow-up question about the file work — so this is a display
    /// transform and must be applied to the find pipeline too, or the
    /// counter names matches nothing tints.
    static func strippingInlineBlocks(from content: String) -> String {
        guard content.contains(openPrefix) else { return content }
        var out = ""
        var rest = Substring(content)
        while let open = rest.range(of: openPrefix) {
            // The tag must CLOSE to count. An unbalanced prefix is the
            // user's own text and is left exactly as typed.
            guard let close = rest.range(of: closeTag, range: open.upperBound..<rest.endIndex)
            else { break }
            out += rest[rest.startIndex..<open.lowerBound]
            rest = rest[close.upperBound...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
