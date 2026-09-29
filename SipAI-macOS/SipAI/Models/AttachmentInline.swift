// AttachmentInline.swift
// The wire format of an inlined text attachment, and the two reads of
// it: what a transcript DRAWS in its place (nothing), and the file
// names the paperclip line under the bubble prints.
//
// One parser for both apps' surfaces. The chat page composes and reads
// the block through `ChatAttachment`; the three agent transcript readers
// (`AgentSessionScanner`, `CodexSessionScanner`, `KimiSessionScanner`)
// read it through this enum directly — this file is Foundation-only so
// the headless reader harnesses can compile it, where `ChatAttachment`
// drags in AppKit, PDFKit and the image pipeline.

import Foundation

enum AttachmentInline {
    /// Opening tag of an inlined block, as written. The strip below
    /// matches this and its closing tag as a PAIR — a bare-tag sweep
    /// would eat a closing angle bracket out of the user's own prose,
    /// which is the trap the agent transcript's local-command reader
    /// already documents.
    static let openPrefix = "<sipai-attachment name=\""
    static let closeTag = "</sipai-attachment>"

    /// Ceiling on the inlined characters ONE MESSAGE may carry, over
    /// every attachment together. On the chat page an attachment is a
    /// content part of an HTTP body; on an agent session the composed
    /// message travels as ONE argv element of the CLI's command line,
    /// and macOS's argument space is 1 MB shared with the environment.
    /// Enforced at attach time, so the refusal is read while picking
    /// files rather than as a spawn that failed.
    static let perMessageCharCap = 200_000

    /// Wrap a text attachment for inlining into the outgoing message.
    /// The name rides the tag so the model can refer to the file by the
    /// name the user sees on the chip.
    static func block(name: String, text: String, truncated: Bool) -> String {
        let escaped = escapeName(name)
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

    /// The DISPLAY marker for an image attachment — a name, no body.
    /// An image's bytes travel a side channel (never the message text),
    /// so this is all that rides the text: enough for the paperclip
    /// line to name the file, live and on reopen, through the same
    /// `stripping` / `names` pair a text attachment uses. It carries no
    /// data, so a transcript record never holds base64. The `image`
    /// attribute is inert to `names` (which reads the name up to the
    /// first quote) and to `stripping` (which keys on the tag pair); it
    /// is there so a person reading the raw record can tell the two
    /// kinds of marker apart.
    static func imageMarker(name: String) -> String {
        "\(openPrefix)\(escapeName(name))\" image=\"true\">\(closeTag)"
    }

    /// What the transcript DRAWS in place of an inlined block: nothing.
    /// The paperclip line under the bubble already names the files, and
    /// a 50k-character dump inside a message bubble is a wall the reader
    /// has to scroll past to reach their own question.
    ///
    /// The stored message keeps the block — that is what makes a
    /// follow-up question about the file work — so this is a display
    /// transform and must be applied wherever a user message is DRAWN
    /// or COUNTED (the find pipeline included), or the counter names
    /// matches nothing tints.
    static func stripping(_ content: String) -> String {
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

    /// The file names an inlined message carries, in order — what the
    /// paperclip line prints. Read off the SAME balanced pairs the strip
    /// removes: an unbalanced tag names nothing, exactly as it strips
    /// nothing, so the line and the bubble can never disagree about
    /// whether a block was there. Names come back unescaped.
    static func names(in content: String) -> [String] {
        guard content.contains(openPrefix) else { return [] }
        var found: [String] = []
        var rest = Substring(content)
        while let open = rest.range(of: openPrefix) {
            guard let close = rest.range(of: closeTag, range: open.upperBound..<rest.endIndex)
            else { break }
            // `name="…"` ends at the first unescaped quote — the writer
            // escapes every quote inside a name as `&quot;`, so the
            // first `"` after the prefix is the closing one.
            let afterPrefix = rest[open.upperBound...]
            if let quote = afterPrefix.firstIndex(of: "\"") {
                let raw = String(afterPrefix[afterPrefix.startIndex..<quote])
                let name = unescapeName(raw)
                if !name.isEmpty { found.append(name) }
            }
            rest = rest[close.upperBound...]
        }
        return found
    }

    /// The paperclip line's text for a message, or nil when it carries
    /// no attachment — the comma-joined shape `ChatMessage.files` uses,
    /// so an agent bubble and a chat bubble read the same.
    static func filesLine(in content: String) -> String? {
        let list = names(in: content)
        return list.isEmpty ? nil : list.joined(separator: ", ")
    }

    private static func escapeName(_ name: String) -> String {
        name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func unescapeName(_ raw: String) -> String {
        // `&amp;` LAST, or `&amp;lt;` would come back as `<`.
        raw.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
