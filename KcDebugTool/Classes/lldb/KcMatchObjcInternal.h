//
//  KcMatchObjcInternal.h
//  Pods
//
//  Created by 张杰 on 2023/9/6.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#if __LP64__
#define KC_OBJC_HAVE_TAGGED_POINTERS 1
#endif

#if KC_OBJC_HAVE_TAGGED_POINTERS

#if TARGET_OS_OSX && __x86_64__
// 64-bit Mac - tag bit is LSB
#   define KC_OBJC_MSB_TAGGED_POINTERS 0
#else
// Everything else - tag bit is MSB
#   define KC_OBJC_MSB_TAGGED_POINTERS 1
#endif

#if KC_OBJC_MSB_TAGGED_POINTERS
#   define KC_OBJC_TAG_MASK (1UL<<63)
#   define KC_OBJC_TAG_EXT_MASK (0xfUL<<60)
#else
#   define KC_OBJC_TAG_MASK 1UL
#   define KC_OBJC_TAG_EXT_MASK 0xfUL
#endif

#endif // OBJC_HAVE_TAGGED_POINTERS

#if __arm64__
#define KC_OBJC_ISA_MASK        0x0000000ffffffff8ULL
#define KC_OBJC_ISA_MAGIC_MASK  0x000003f000000001ULL
#define KC_OBJC_ISA_MAGIC_VALUE 0x000001a000000001ULL
#elif __x86_64__
#define KC_OBJC_ISA_MASK        0x00007ffffffffff8ULL
#define KC_OBJC_ISA_MAGIC_MASK  0x001f800000000001ULL
#define KC_OBJC_ISA_MAGIC_VALUE 0x001d800000000001ULL
#else
//#error unknown architecture for packed isa
#define KC_OBJC_ISA_MASK         0
#define KC_OBJC_ISA_MAGIC_MASK   0
#define KC_OBJC_ISA_MAGIC_VALUE  0
#endif


@interface KcMatchObjcInternal : NSObject

// 参考: https://blog.timac.org/2016/1124-testing-if-an-arbitrary-pointer-is-a-valid-objective-c-object/
// https://github.com/NativeScript/ios-jsc
// FLEX库 - FLEXHeapEnumerator、FLEXObjcInternal
// 注意：去除了`IsObjcTaggedPointer`的判断
/**
 Test if a pointer is an Objective-C object

 @param inPtr is the pointer to check
 @return true if the pointer is an Objective-C object
 
 能够识别swift class、嵌套在某个命名空间里面的swift class
 */
//bool isObjcObject(const void *inPtr, const Class *allClasses, int classCount);
//static bool isObjcObject(const void *inPtr, const Class *allClasses, int classCount)

+ (BOOL)isObjcObject:(const void *)inPtr registeredClasses:(nullable CFMutableSetRef)registeredClasses;


/// Accepts addresses that may or may not be readable.
/// https://blog.timac.org/2016/1124-testing-if-an-arbitrary-pointer-is-a-valid-objective-c-object/
+ (BOOL)isValidReadableMemory:(const void *)inPtr;

@end

NS_ASSUME_NONNULL_END
