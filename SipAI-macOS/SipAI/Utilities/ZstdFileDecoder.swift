// ZstdFileDecoder.swift
// zstd's decoder over one file: how SipAI reads codex's compressed
// rollouts (`.jsonl.zst`, see `SessionFileCompression`).
//
// The decoder is zstd's own, bundled in `Vendor/zstd` (decompression
// only, under its BSD licence) and reached through the bridging header;
// this file is the stream around it. macOS has no zstd of its own to use
// instead: the Compression framework offers LZ4, zlib, LZMA, Brotli,
// LZFSE and LZBitmap, and the system libarchive is built without zstd.

import Foundation

final class ZstdFileDecoder: SessionFileDecoder {
    private let handle: FileHandle
    private let stream: OpaquePointer
    private let inputChunk: Int
    private var input = Data()
    private var inputOffset = 0
    private var inputEnded = false
    private var finished = false

    private init(handle: FileHandle, stream: OpaquePointer) {
        self.handle = handle
        self.stream = stream
        inputChunk = max(ZSTD_DStreamInSize(), 1 << 16)
    }

    deinit {
        ZSTD_freeDStream(stream)
        try? handle.close()
    }

    /// What `SessionFileCompression.decoder` is set to at launch.
    static func open(_ url: URL) -> SessionFileDecoder? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        guard let stream = ZSTD_createDStream() else {
            try? handle.close()
            return nil
        }
        // A frame may ask for a window up to zstd's own default bound,
        // 128 MiB (codex's ask for 2 MiB at most); one that asks for more
        // fails to decode and reads as ending there.
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else {
            ZSTD_freeDStream(stream)
            try? handle.close()
            return nil
        }
        return ZstdFileDecoder(handle: handle, stream: stream)
    }

    /// The decoded size the file's first frame states — codex compresses
    /// a rollout as one frame and states it — or nil when the frame
    /// states none or the file does not start with a frame. What
    /// `SessionFileCompression.statedSize` is set to.
    static func statedSize(_ url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // A frame header is 18 bytes at most.
        guard let head = try? handle.read(upToCount: 18), !head.isEmpty else { return nil }
        let size = head.withUnsafeBytes { raw in
            ZSTD_getFrameContentSize(raw.baseAddress, raw.count)
        }
        // The two largest values are zstd's "not stated" and "not a frame".
        guard size < UInt64.max - 1 else { return nil }
        return size
    }

    func read(upToCount count: Int) -> Data {
        guard count > 0, !finished else { return Data() }
        var out = Data(count: count)
        let produced: Int = out.withUnsafeMutableBytes { raw -> Int in
            var output = ZSTD_outBuffer(dst: raw.baseAddress, size: count, pos: 0)
            while output.pos < output.size, !finished {
                if inputOffset >= input.count, !inputEnded {
                    let more = (try? handle.read(upToCount: inputChunk)) ?? Data()
                    if more.isEmpty {
                        inputEnded = true
                    } else {
                        input = more
                        inputOffset = 0
                    }
                }
                let before = output.pos
                let result: Int = input.withUnsafeBytes { source -> Int in
                    var inBuffer = ZSTD_inBuffer(src: source.baseAddress,
                                                 size: source.count, pos: inputOffset)
                    let r = ZSTD_decompressStream(stream, &output, &inBuffer)
                    inputOffset = inBuffer.pos
                    return r
                }
                // A frame that does not decode ends the text where it
                // stops making sense; a file cut off mid-frame ends where
                // the bytes do, once nothing more comes out.
                if ZSTD_isError(result) != 0 {
                    finished = true
                } else if inputEnded, inputOffset >= input.count, output.pos == before {
                    finished = true
                }
            }
            return output.pos
        }
        return produced == count ? out : out.prefix(produced)
    }
}
