import Foundation

// Swift String is a two-word value whose ownership cannot be reproduced by
// Objective-C ARC. These small C entry points only pack/unpack that value;
// expression parsing, symbol lookup and invocation stay in Objective-C.
private final class KCStringBox {
    let value: String
    init(_ value: String) { self.value = value }
}

@_cdecl("KCObjCEvalCreateSwiftStringWords")
public func KCObjCEvalCreateSwiftStringWords(_ object: UnsafeRawPointer,
                                              _ words: UnsafeMutablePointer<UInt64>) -> UnsafeMutableRawPointer {
    let text = Unmanaged<NSString>.fromOpaque(object).takeUnretainedValue() as String
    let box = KCStringBox(text)
    precondition(MemoryLayout<String>.size == 2 * MemoryLayout<UInt64>.size)
    withUnsafeBytes(of: box.value) { bytes in
        words[0] = bytes.load(fromByteOffset: 0, as: UInt64.self)
        words[1] = bytes.load(fromByteOffset: 8, as: UInt64.self)
    }
    return Unmanaged.passRetained(box).toOpaque()
}

@_cdecl("KCObjCEvalReleaseSwiftStringWords")
public func KCObjCEvalReleaseSwiftStringWords(_ box: UnsafeMutableRawPointer) {
    Unmanaged<KCStringBox>.fromOpaque(box).release()
}

@_cdecl("KCObjCEvalCopyNSStringFromSwiftStringWords")
public func KCObjCEvalCopyNSStringFromSwiftStringWords(_ words: UnsafePointer<UInt64>) -> UnsafeMutableRawPointer {
    // Swift's native return is owned (+1). Rebuilding a String consumes that
    // ownership, then the returned NSString is retained for Objective-C ARC.
    let bits = (words[0], words[1])
    let value = unsafeBitCast(bits, to: String.self)
    return Unmanaged.passRetained(value as NSString).toOpaque()
}
