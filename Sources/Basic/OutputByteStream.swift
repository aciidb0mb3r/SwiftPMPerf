/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

/// Convert an integer in 0..<16 to its hexadecimal ASCII character.
private func hexdigit(_ value: UInt8) -> UInt8 {
    return value < 10 ? (0x30 + value) : (0x41 + value - 10)
}

/// Describes a type which can be written to a byte stream.
public protocol ByteStreamable {
    func write(to stream: OutputByteStream)
}

/// An output byte stream.
///
/// This class is designed to be able to support efficient streaming to
/// different output destinations, e.g., a file or an in memory buffer. This is
/// loosely modeled on LLVM's llvm::raw_ostream class.
///
/// The stream is generally used in conjunction with the custom streaming
/// operator '<<<'. For example:
///
///   let stream = OutputByteStream()
///   stream <<< "Hello, world!"
///
/// would write the UTF8 encoding of "Hello, world!" to the stream.
///
/// The stream accepts a number of custom formatting operators which are defined
/// in the `Format` struct (used for namespacing purposes). For example:
/// 
///   let items = ["hello", "world"]
///   stream <<< Format.asSeparatedList(items, separator: " ")
///
/// would write each item in the list to the stream, separating them with a
/// space.
public class OutputByteStream: TextOutputStream {
    /// The data buffer.
    /// Note: Minimum Buffer size should be one.
    //private var buffer: [UInt8]
    var buffer: UnsafeMutablePointer<UInt8>
    var count = 0

    /// Default buffer size of the data buffer.
    private static let bufferSize = 1024

    init() {
        self.buffer = UnsafeMutablePointer.allocate(capacity: 1024)
     //   self.buffer = []
     //   self.buffer.reserveCapacity(OutputByteStream.bufferSize)
    }

    // MARK: Data Access API

    /// The current offset within the output stream.
    public final var position: Int {
        return count
    }

    /// Currently available buffer size.
    private var availableBufferSize: Int {
        return 1024 - count
    }

     /// Clears the buffer maintaining current capacity.
    private func clearBuffer() {
        count = 0
        //buffer.removeAll(keepingCapacity: true)
    }

    // MARK: Data Output API
    private func dump() {
        let buf = UnsafeBufferPointer(start: buffer, count: count)
        writeImpl(buf)
    }

    public final func flush() {
        dump()
        clearBuffer()
        flushImpl()
    }

    func flushImpl() {
        // Do nothing.
    }

    //func writeImpl<C: Collection where C.Iterator.Element == UInt8>(_ bytes: C) {
    func writeImpl(_ ptr: UnsafeBufferPointer<UInt8>) {
        fatalError("Subclasses must implement this")
    }

    /// Write an individual byte to the buffer.
    public final func write(_ byte: UInt8) {
        // If buffer is full, write and clear it.
        if availableBufferSize == 0 {
            dump()
            clearBuffer()
        }

        // This will need to change change if we ever have unbuffered stream.
        precondition(availableBufferSize > 0)
        buffer[count] = byte
        count += 1
    }

    /// Write the contents of a UnsafeBufferPointer<UInt8>.
    final func write(_ bytes: UnsafeBufferPointer<UInt8>) {
        // This is based on LLVM's raw_ostream.
        let availableBufferSize = self.availableBufferSize

        // If we have to insert more than the available space in buffer.
        if bytes.count > availableBufferSize {
            // If buffer is empty, start writing and keep the last chunk in buffer.
            if count == 0 {
                let bytesToWrite = bytes.count - (bytes.count % availableBufferSize)
                writeImpl(UnsafeBufferPointer(start: bytes.baseAddress, count: bytesToWrite))

                // If remaining bytes is more than buffer size write everything.
                let bytesRemaining = bytes.count - bytesToWrite
                if bytesRemaining > availableBufferSize {
                    writeImpl(UnsafeBufferPointer(start: bytes.baseAddress! + bytesToWrite, count: bytes.count - bytesToWrite))
                    return
                }
                // Otherwise keep remaining in buffer.
                let cnt = bytes.count - bytesToWrite
                (buffer + count).initialize(from:  bytes.baseAddress! + bytesToWrite, count: cnt)
                count += cnt
                return
            }

            // Append whatever we can accomodate.
            (buffer + count).initialize(from: bytes.baseAddress!, count: availableBufferSize)
            count += availableBufferSize

            dump()
            clearBuffer()

            // FIXME: We should start again with remaining chunk but this doesn't work. Write everything for now.
            //write(UnsafeBufferPointer(start: bytes.baseAddress! + availableBufferSize, count: bytes.count - availableBufferSize))
            writeImpl(UnsafeBufferPointer(start: bytes.baseAddress! + availableBufferSize, count: bytes.count - availableBufferSize))
            return
        }
        (buffer + count).initialize(from: bytes.baseAddress!, count: bytes.count)
        count += bytes.count
    }
    
    /// Write a sequence of bytes to the buffer.
    public final func write(_ bytes: ArraySlice<UInt8>) {
        write(bytes)
    }

    /// Write a sequence of bytes to the buffer.
    public final func write(_ bytes: [UInt8]) {
        write(bytes)
    }
    
    /// Write a sequence of bytes to the buffer.
    public final func write<S: Sequence where S.Iterator.Element == UInt8>(_ sequence: S) {
        // Iterate the sequence and append byte by byte since sequence's append
        // is not performant anyway.
        for byte in sequence {
            write(byte)
        }
    }

    /// Write a string to the buffer (as UTF8).
    public final func write(_ string: String) {
        // Fast path for contiguous strings. For some reason Swift itself
        // doesn't implement this optimization: <rdar://problem/24100375> Missing fast path for [UInt8] += String.UTF8View
        let stringPtrStart = string._contiguousUTF8
        if stringPtrStart != nil {
            write(UnsafeBufferPointer(start: stringPtrStart, count: string.utf8.count))
        } else {
            write(string.utf8)
        }
    }

    /// Write a character to the buffer (as UTF8).
    public final func write(_ character: Character) {
        write(String(character))
    }

    /// Write an arbitrary byte streamable to the buffer.
    public final func write(_ value: ByteStreamable) {
        value.write(to: self)
    }

    /// Write an arbitrary streamable to the buffer.
    public final func write(_ value: Streamable) {
        // Get a mutable reference.
        var stream: OutputByteStream = self
        value.write(to: &stream)
    }

    /// Write a string (as UTF8) to the buffer, with escaping appropriate for
    /// embedding within a JSON document.
    ///
    /// NOTE: This writes the literal data applying JSON string escaping, but
    /// does not write any other characters (like the quotes that would surround
    /// a JSON string).
    public final func writeJSONEscaped(_ string: String) {
        // See RFC7159 for reference: https://tools.ietf.org/html/rfc7159
        for character in string.utf8 {
            // Handle string escapes; we use constants here to directly match the RFC.
            switch character {
                // Literal characters.
            case 0x20...0x21, 0x23...0x5B, 0x5D...0xFF:
                write(character)
            
                // Single-character escaped characters.
            case 0x22: // '"'
                write(0x5C) // '\'
                write(0x22) // '"'
            case 0x5C: // '\\'
                write(0x5C) // '\'
                write(0x5C) // '\'
            case 0x08: // '\b'
                write(0x5C) // '\'
                write(0x62) // 'b'
            case 0x0C: // '\f'
                write(0x5C) // '\'
                write(0x66) // 'b'
            case 0x0A: // '\n'
                write(0x5C) // '\'
                write(0x6E) // 'n'
            case 0x0D: // '\r'
                write(0x5C) // '\'
                write(0x72) // 'r'
            case 0x09: // '\t'
                write(0x5C) // '\'
                write(0x74) // 't'

                // Multi-character escaped characters.
            default:
                write(0x5C) // '\'
                write(0x75) // 'u'
                write(hexdigit(0))
                write(hexdigit(0))
                write(hexdigit(character >> 4))
                write(hexdigit(character & 0xF))
            }
        }
    }
}
    
/// Define an output stream operator. We need it to be left associative, so we
/// use `<<<`.
infix operator <<< { associativity left }

// MARK: Output Operator Implementations
//
// NOTE: It would be nice to use a protocol here and the adopt it by all the
// things we can efficiently stream out. However, that doesn't work because we
// ultimately need to provide a manual overload sometimes, e.g., Streamable, but
// that will then cause ambiguous lookup versus the implementation just using
// the defined protocol.

@discardableResult
public func <<<(stream: OutputByteStream, value: UInt8) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: [UInt8]) -> OutputByteStream {
    value.withUnsafeBufferPointer { x in
        stream.write(x)
    }
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: ArraySlice<UInt8>) -> OutputByteStream {
    value.withUnsafeBufferPointer { x in
        stream.write(x)
    }
    return stream
}

@discardableResult
public func <<<<S: Sequence where S.Iterator.Element == UInt8>(stream: OutputByteStream, value: S) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: String) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: Character) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: ByteStreamable) -> OutputByteStream {
    stream.write(value)
    return stream
}

@discardableResult
public func <<<(stream: OutputByteStream, value: Streamable) -> OutputByteStream {
    stream.write(value)
    return stream
}

extension UInt8: ByteStreamable {
    public func write(to stream: OutputByteStream) {
        stream.write(self)
    }
}

extension Character: ByteStreamable {
    public func write(to stream: OutputByteStream) {
        stream.write(self)
    }
}

extension String: ByteStreamable {
    public func write(to stream: OutputByteStream) {
        stream.write(self)
    }
}

// MARK: Formatted Streaming Output

// Not nested because it is generic.
private struct SeparatedListStreamable<T: ByteStreamable>: ByteStreamable {
    let items: [T]
    let separator: String
    
    func write(to stream: OutputByteStream) {
        for (i, item) in items.enumerated() {
            // Add the separator, if necessary.
            if i != 0 {
                stream <<< separator
            }
            
            stream <<< item
        }
    }
}

// Not nested because it is generic.
private struct TransformedSeparatedListStreamable<T>: ByteStreamable {
    let items: [T]
    let transform: (T) -> ByteStreamable
    let separator: String
    
    func write(to stream: OutputByteStream) {
        for (i, item) in items.enumerated() {
            if i != 0 { stream <<< separator }
            stream <<< transform(item)
        }
    }
}

// Not nested because it is generic.
private struct JSONEscapedTransformedStringListStreamable<T>: ByteStreamable {
    let items: [T]
    let transform: (T) -> String

    func write(to stream: OutputByteStream) {
        stream <<< UInt8(ascii: "[")
        for (i, item) in items.enumerated() {
            if i != 0 { stream <<< "," }
            stream <<< Format.asJSON(transform(item))
        }
        stream <<< UInt8(ascii: "]")
    }
}

/// Provides operations for returning derived streamable objects to implement various forms of formatted output.
public struct Format {
    /// Write the input boolean encoded as a JSON object.
    static public func asJSON(_ value: Bool) -> ByteStreamable {
        return JSONEscapedBoolStreamable(value: value)
    }
    private struct JSONEscapedBoolStreamable: ByteStreamable {
        let value: Bool
        
        func write(to stream: OutputByteStream) {
            stream <<< (value ? "true" : "false")
        }
    }

    /// Write the input integer encoded as a JSON object.
    static public func asJSON(_ value: Int) -> ByteStreamable {
        return JSONEscapedIntStreamable(value: value)
    }
    private struct JSONEscapedIntStreamable: ByteStreamable {
        let value: Int
        
        func write(to stream: OutputByteStream) {
            // FIXME: Diagnose integers which cannot be represented in JSON.
            stream <<< value.description
        }
    }

    /// Write the input double encoded as a JSON object.
    static public func asJSON(_ value: Double) -> ByteStreamable {
        return JSONEscapedDoubleStreamable(value: value)
    }
    private struct JSONEscapedDoubleStreamable: ByteStreamable {
        let value: Double
        
        func write(to stream: OutputByteStream) {
            // FIXME: What should we do about NaN, etc.?
            //
            // FIXME: Is Double.debugDescription the best representation?
            stream <<< value.debugDescription
        }
    }

    /// Write the input string encoded as a JSON object.
    static public func asJSON(_ string: String) -> ByteStreamable {
        return JSONEscapedStringStreamable(value: string)
    }
    private struct JSONEscapedStringStreamable: ByteStreamable {
        let value: String
        
        func write(to stream: OutputByteStream) {
            stream <<< UInt8(ascii: "\"")
            stream.writeJSONEscaped(value)
            stream <<< UInt8(ascii: "\"")
        }
    }
    
    /// Write the input string list encoded as a JSON object.
    //
    // FIXME: We might be able to make this more generic through the use of a "JSONEncodable" protocol.
    static public func asJSON(_ items: [String]) -> ByteStreamable {
        return JSONEscapedStringListStreamable(items: items)
    }
    private struct JSONEscapedStringListStreamable: ByteStreamable {
        let items: [String]
        
        func write(to stream: OutputByteStream) {
            stream <<< UInt8(ascii: "[")
            for (i, item) in items.enumerated() {
                if i != 0 { stream <<< "," }
                stream <<< Format.asJSON(item)
            }
            stream <<< UInt8(ascii: "]")
        }
    }

    /// Write the input dictionary encoded as a JSON object.
    static public func asJSON(_ items: [String: String]) -> ByteStreamable {
        return JSONEscapedDictionaryStreamable(items: items)
    }
    private struct JSONEscapedDictionaryStreamable: ByteStreamable {
        let items: [String: String]
        
        func write(to stream: OutputByteStream) {
            stream <<< UInt8(ascii: "{")
            for (offset: i, element: (key: key, value: value)) in items.enumerated() {
                if i != 0 { stream <<< "," }
                stream <<< Format.asJSON(key) <<< ":" <<< Format.asJSON(value)
            }
            stream <<< UInt8(ascii: "}")
        }
    }

    /// Write the input list (after applying a transform to each item) encoded as a JSON object.
    //
    // FIXME: We might be able to make this more generic through the use of a "JSONEncodable" protocol.
    static public func asJSON<T>(_ items: [T], transform: (T) -> String) -> ByteStreamable {
        return JSONEscapedTransformedStringListStreamable(items: items, transform: transform)
    }

    /// Write the input list to the stream with the given separator between items.
    static public func asSeparatedList<T: ByteStreamable>(_ items: [T], separator: String) -> ByteStreamable {
        return SeparatedListStreamable(items: items, separator: separator)
    }

    /// Write the input list to the stream (after applying a transform to each item) with the given separator between items.
    static public func asSeparatedList<T>(_ items: [T], transform: (T) -> ByteStreamable, separator: String) -> ByteStreamable {
        return TransformedSeparatedListStreamable(items: items, transform: transform, separator: separator)
    }
}

/// Inmemory implementation of OutputByteStream.
public final class BufferedOutputByteStream: OutputByteStream {

    /// Contents of the stream.
    // FIXME: For inmemory implementation we should be share this buffer with OutputByteStream.
    // One way to do this is by allowing OuputByteStream to install external buffers.
    private var contents = [UInt8]()

    override public init() {
        super.init()
    }

    /// The contents of the output stream.
    ///
    /// Note: This implicitly flushes the stream.
    public var bytes: ByteString {
        flush()
        return ByteString(contents)
    }

    override final func flushImpl() {
        // Do nothing.
    }

    override final func writeImpl(_ ptr: UnsafeBufferPointer<UInt8>) {
        contents += ptr 
    }
}
