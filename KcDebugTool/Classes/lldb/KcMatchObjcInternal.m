//
//  KcMatchObjcInternal.m
//  Pods
//
//  Created by 张杰 on 2023/9/6.
//

#import "KcMatchObjcInternal.h"
#import <objc/runtime.h>
// For malloc_size
#import <malloc/malloc.h>
// For vm_region_64
#include <mach/mach.h>

#if __arm64e__
#import <ptrauth.h>
#endif

////////////////////////////////////////////////
// originally objc_object::isExtTaggedPointer //
////////////////////////////////////////////////
static inline BOOL kc_objc_isExtTaggedPointer(const void *ptr)  {
    return ((uintptr_t)ptr & KC_OBJC_TAG_EXT_MASK) == KC_OBJC_TAG_EXT_MASK;
}

//////////////////////////////////////
// originally _objc_isTaggedPointer //
//////////////////////////////////////
static inline BOOL kc_isTaggedPointer(const void *ptr)  {
    #if KC_OBJC_HAVE_TAGGED_POINTERS
        return ((uintptr_t)ptr & KC_OBJC_TAG_MASK) == KC_OBJC_TAG_MASK;
    #else
        return NO;
    #endif
}

/// 是否是swift的class - 来自 objc-internal.h
BOOL _class_isSwift(Class _Nullable cls);

@implementation KcMatchObjcInternal

// 参考: https://blog.timac.org/2016/1124-testing-if-an-arbitrary-pointer-is-a-valid-objective-c-object/
// https://github.com/NativeScript/ios-jsc
// 注意：去除了`IsObjcTaggedPointer`的判断
/**
 Test if a pointer is an Objective-C object

 @param inPtr is the pointer to check
 @return true if the pointer is an Objective-C object
 
 能够识别swift class、嵌套在某个命名空间里面的swift class
 */
//bool isObjcObject(const void *inPtr, const Class *allClasses, int classCount);
//static bool isObjcObject(const void *inPtr, const Class *allClasses, int classCount)

+ (BOOL)isObjcObject:(const void *)inPtr registeredClasses:(CFMutableSetRef)registeredClasses {
    //
    // NULL pointer is not an Objective-C object
    //
    if (inPtr == NULL) {
        return false;
    }

    //
    // Check for tagged pointers
    //
    //    if(IsObjcTaggedPointer(inPtr, NULL))
    //    {
    //        return true;
    //    }
    // 直接把这个过滤掉, 本来它其实是算objc的
    if (kc_isTaggedPointer(inPtr) || kc_objc_isExtTaggedPointer(inPtr)) {
        return false;
    }

    //
    // Check if the pointer is aligned
    //
    if (((uintptr_t)inPtr % sizeof(uintptr_t)) != 0) {
        return false;
    }

    //
    // From LLDB:
    // Objective-C runtime has a rule that pointers in a class_t will only have bits 0 thru 46 set
    // so if any pointer has bits 47 thru 63 high we know that this is not a valid isa
    // See http://llvm.org/svn/llvm-project/lldb/trunk/examples/summaries/cocoa/objc_runtime.py
    //
    if (((uintptr_t)inPtr & 0xFFFF800000000000) != 0) {
        return false;
    }

    //
    // Check if the memory is valid and readable
    //
    if (![self isValidReadableMemory:inPtr]) {
        return false;
    }

    //
    // Get the Class from the pointer
    // From http://www.sealiesoftware.com/blog/archive/2013/09/24/objc_explain_Non-pointer_isa.html :
    // If you are writing a debugger-like tool, the Objective-C runtime exports some variables
    // to help decode isa fields. objc_debug_isa_class_mask describes which bits are the class pointer:
    // (isa & class_mask) == class pointer.
    // objc_debug_isa_magic_mask and objc_debug_isa_magic_value describe some bits that help
    // distinguish valid isa fields from other invalid values:
    // (isa & magic_mask) == magic_value for isa fields that are not raw class pointers.
    // These variables may change in the future so do not use them in application code.
    //
    // FLEX通过object_getClass获取的
    uintptr_t isa = (*(uintptr_t *)inPtr);
    Class ptrClass = NULL;

    /*
     struct swift_class_t : objc_class {
     
     struct objc_class : objc_object {
     
     struct objc_object {
     private:
         isa_t isa;
     ...
     }
     
    */
    if ((isa & ~KC_OBJC_ISA_MASK) == 0) {
        ptrClass = (__bridge Class)(void *)isa;
    } else {
        // 即使是non-pointer isa, isa & isa_magic_mask == isa_magic_value 条件也不成立，先取消判断。
        // isa & isa_magic_mask != isa_magic_value
        ptrClass = (__bridge Class)(void *)(isa & KC_OBJC_ISA_MASK);
//        if ((isa & KC_OBJC_ISA_MAGIC_MASK) == KC_OBJC_ISA_MAGIC_VALUE) {
//            ptrClass = (Class)(isa & KC_OBJC_ISA_MASK);
//        } else {
//            ptrClass = (Class)isa;
//        }
    }

    if (ptrClass == NULL || ![self isValidReadableMemory:(void *)ptrClass]) {
        return false;
    }
    
    // ios15 会 crash⚠️
    // Just because this pointer is readable doesn't mean whatever is at
    // it's ISA offset is readable. We need to do the same checks on it's ISA.
    // Even this isn't perfect, because once we call object_isClass, we're
    // going to dereference a member of the metaclass, which may or may not
    // be readable itself. For the time being there is no way to access it
    // to check here, and I have yet to hard-code a solution.
//    Class metaclass = object_getClass(ptrClass);
//    if (!metaclass || !KC_isValidReadableMemory((void *)metaclass)) {
//        return NO;
//    }
    
    // Does the class pointer we got appear as a class to the runtime?
//    if (!object_isClass(ptrClass)) {
//        return NO;
//    }

    //
    // Verifies that the found Class is a known class.
    //
    bool isKnownClass = false;
    if (CFSetContainsValue(registeredClasses, (__bridge const void *)(ptrClass))) {
        isKnownClass = true;
    }

    if (!isKnownClass) {
        return false;
    }

    //
    // From Greg Parker
    // https://twitter.com/gparker/status/801894068502433792
    // You can filter out some false positives by checking malloc_size(obj) >= class_getInstanceSize(cls).
    //
    size_t pointerSize = malloc_size(inPtr);
    if (pointerSize > 0 && pointerSize < class_getInstanceSize(ptrClass)) {
        return false;
    }

    return true;
}

+ (BOOL)isValidReadableMemory:(const void *)inPtr {
    kern_return_t error = KERN_SUCCESS;

    // Check for read permissions
    bool hasReadPermissions = false;

    vm_size_t vmsize;
#if __arm64e__
    // On arm64e, we need to strip the PAC from the pointer so the adress is readable
    vm_address_t address = (vm_address_t)ptrauth_strip(inPtr, ptrauth_key_function_pointer);
#else
    vm_address_t address = (vm_address_t)inPtr;
#endif
    vm_region_basic_info_data_t info;
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;

    memory_object_name_t object;

    error = vm_region_64(mach_task_self(), &address, &vmsize, VM_REGION_BASIC_INFO, (vm_region_info_t)&info, &info_count, &object);
    if (error != KERN_SUCCESS) {
        // vm_region/vm_region_64 returned an error
        hasReadPermissions = false;
    } else {
        hasReadPermissions = (info.protection & VM_PROT_READ);
    }

    if (!hasReadPermissions) {
        return false;
    }
    
#if __arm64e__
    address = (vm_address_t)ptrauth_strip(inPtr, ptrauth_key_function_pointer);
#else
    address = (vm_address_t)inPtr;
#endif

    // Read the memory
    char buf[sizeof(uintptr_t)];
    vm_size_t size = 0;
    error = vm_read_overwrite(mach_task_self(), (vm_address_t)address, sizeof(uintptr_t), (vm_address_t)buf, &size);
    if (error != KERN_SUCCESS) {
        // vm_read returned an error
        return false;
    }

    return true;
}

@end
