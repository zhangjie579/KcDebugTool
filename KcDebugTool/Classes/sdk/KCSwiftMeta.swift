//
//  KCSwiftMeta.swift
//  KcDebugTool_Example
//
//  Created by 张杰 on 2021/5/15.
//  Copyright © 2021 张杰. All rights reserved.
//  导出swift符号

import UIKit

@objc(KCSwiftMeta)
@objcMembers
public class KCSwiftMeta: NSObject {

}

public extension KCSwiftMeta {
    /** pointer to a function implementing a Swift method */
    typealias SIMP = @convention(c) () -> Void

    /**
     Value that crops up as a ClassSize since 5.2 runtime
     */
    static let invalidClassSize = 0x50AF17B0

    /**
     Layout of a class instance. Needs to be kept in sync with ~swift/include/swift/Runtime/Metadata.h
     */
    struct TargetClassMetadata {

        let MetaClass: uintptr_t = 0, SuperClass: uintptr_t = 0
        let CacheData1: uintptr_t = 0, CacheData2: uintptr_t = 0

        public let Data: uintptr_t = 0

        /// Swift-specific class flags.
        public let Flags: UInt32 = 0

        /// The address point of instances of this type.
        public let InstanceAddressPoint: UInt32 = 0

        /// The required size of instances of this type.
        /// 'InstanceAddressPoint' bytes go before the address point;
        /// 'InstanceSize - InstanceAddressPoint' bytes go after it.
        public let InstanceSize: UInt32 = 0

        /// The alignment mask of the address point of instances of this type.
        public let InstanceAlignMask: UInt16 = 0

        /// Reserved for runtime use.
        public let Reserved: UInt16 = 0

        /// The total size of the class object, including prefix and suffix
        /// extents.
        public let ClassSize: UInt32 = 0

        /// The offset of the address point within the class object.
        public let ClassAddressPoint: UInt32 = 0

        /// An out-of-line Swift-specific description of the type, or null
        /// if this is an artificial subclass.  We currently provide no
        /// supported mechanism for making a non-artificial subclass
        /// dynamically.
        public let Description: uintptr_t = 0

        /// A function for destroying instance variables, used to clean up
        /// after an early return from a constructor.
        public var IVarDestroyer: SIMP? = nil

        // After this come the class members, laid out as follows:
        //   - class members for the superclass (recursively)
        //   - metadata reference for the parent, if applicable
        //   - generic parameters for this class
        //   - class variables (if we choose to support these)
        //   - "tabulated" virtual methods

    }
}

@objc
public extension KCSwiftMeta {
    /// 所有swift方法 as demangled symbols
    /// demo: [KCSwiftMeta methodNamesOfClass:class]
    class func methodNames(ofClass: AnyClass) -> [String] {
        var names = [String]()
        iterateMethods(ofClass: ofClass) {
            (name, slotIndex, vtableSlot, stop) in
            names.append(name)
        }
        return names
    }
    
    /** symbol name -> 人类可读的Swift语言形式
     Convert a executable symbol name "mangled" according to Swift's
     conventions into a human readable Swift language form
     */
    class func demangle(symbol: UnsafePointer<Int8>) -> String? {
        if let demangledNamePtr = _stdlib_demangleImpl(
            symbol, mangledNameLength: UInt(strlen(symbol)),
            outputBuffer: nil, outputBufferSize: nil, flags: 0) {
            let demangledName = String(cString: demangledNamePtr)
            free(demangledNamePtr)
            return demangledName
        }
        return nil
    }
    
    /// 还原二进制中swift函数名
    /// 命令行工具: xcrun swift-demangle 二进制中的函数名
    /// expr -l objc++ -O -- [KCSwiftMeta demangleName:@"_TtCO7SawaKSA9HomeChild17KSAViewController"]
    class func demangleName(_ mangledName: String) -> String {
        return mangledName.utf8CString.withUnsafeBufferPointer {
            (mangledNameUTF8) in

            let demangledNamePtr = _stdlib_demangleImpl(
                mangledNameUTF8.baseAddress,
                mangledNameLength: UInt(mangledNameUTF8.count - 1),
                outputBuffer: nil,
                outputBufferSize: nil,
                flags: 0)

            if let demangledNamePtr = demangledNamePtr {
                let demangledName = String(cString: demangledNamePtr)
                free(demangledNamePtr)
                return demangledName
            }
            return mangledName
        }
    }
}

public extension KCSwiftMeta {
    /** 遍历虚函数表vTable, 通过改变虚函数的point来hook函数
     Iterate over all methods in the vtable that follows the class information 遍历vtable中所有方法
     of a Swift class (TargetClassMetadata)
     - parameter aClass: the class, the methods of which to trace
     - parameter callback: per method callback
     */
    @discardableResult
    class func iterateMethods(ofClass aClass: AnyClass,
                                   callback: (_ name: String, _ slotIndex: Int,
                                              _ vtableSlot: UnsafeMutablePointer<SIMP>,
                                              _ stop: inout Bool) -> Void) -> Bool {
        let swiftMeta: UnsafeMutablePointer<KCSwiftMeta.TargetClassMetadata> = autoBitCast(aClass)
        let className = NSStringFromClass(aClass)
        var stop = false

        // 1.过滤
        guard (className.hasPrefix("_Tt") || className.contains(".")) &&
                !className.hasPrefix("Swift.") else {//} && class_getSuperclass(aClass) != nil else {
            //print("Object is not instance of Swift class")
            return false
        }

        // 2.vTable
        let endMeta = UnsafeMutablePointer<Int8>(cast: swiftMeta) -
            Int(swiftMeta.pointee.ClassAddressPoint) +
            Int(swiftMeta.pointee.ClassSize)
        let vtableStart = UnsafeMutablePointer<SIMP?>(cast:
            &swiftMeta.pointee.IVarDestroyer)
        let vtableEnd = UnsafeMutablePointer<SIMP?>(cast: endMeta)

        var info = Dl_info()
        for slotIndex in 0..<(vtableEnd - vtableStart) {
            guard let impl: IMP = autoBitCast(vtableStart[slotIndex]) else {
                continue
            }
            let voidPtr: UnsafeMutableRawPointer = autoBitCast(impl)
            if dladdr(voidPtr, &info) != 0, let symname = info.dli_sname,
               let symlast = info.dli_sname?.advanced(by: strlen(symname)-1),
               symlast.pointee == UInt8(ascii: "C") ||
                symlast.pointee == UInt8(ascii: "D") ||
                symlast.pointee == UInt8(ascii: "F"),
               let demangled = KCSwiftMeta.demangle(symbol: symname) {
                callback(demangled, slotIndex,
                         &vtableStart[slotIndex]!, &stop)
                if stop {
                    break
                }
            }
        }
        return stop
    }
}

public extension KCSwiftMeta {
    /// 是否是属性
    class func isProperty(aClass: AnyClass, sel: Selector) -> Bool {
        var name = [Int8](repeating: 0, count: 5000)
        strcpy(&name, sel_getName(sel))
        if strncmp(name, "is", 2) == 0 && isupper(Int32(name[2])) != 0 {
            name[2] = Int8(towlower(Int32(name[2]))) // 小写
            return class_getProperty(aClass, &name[2]) != nil
        }
        else if strncmp(name, "set", 3) != 0 || islower(Int32(name[3])) != 0 { // set属性
            return class_getProperty(aClass, name) != nil
        }
        else {
            name[3] = Int8(tolower(Int32(name[3])))
            name[Int(strlen(name))-1] = 0
            return class_getProperty(aClass, &name[3]) != nil
        }
    }
}

// Taken from stdlib, not public Swift3+
@_silgen_name("swift_demangle")
private
func _stdlib_demangleImpl(
    _ mangledName: UnsafePointer<CChar>?,
    mangledNameLength: UInt,
    outputBuffer: UnsafeMutablePointer<UInt8>?,
    outputBufferSize: UnsafeMutablePointer<UInt>?,
    flags: UInt32
    ) -> UnsafeMutablePointer<CChar>?

//@_silgen_name("swift_EnumCaseName")
//func _getEnumCaseName<T>(_ value: T) -> UnsafePointer<CChar>?
