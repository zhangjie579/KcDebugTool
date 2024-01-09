//
//  KcHeapObjcManager.m
//  Pods
//
//  Created by 张杰 on 2023/9/6.
//

#import "KcHeapObjcManager.h"
#import <objc/runtime.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import "KcMatchObjcInternal.h"
#import <dlfcn.h>

static CFMutableSetRef registeredClasses;

// Mimics the objective-c object structure for checking if a range of memory is an object.
typedef struct {
    Class isa;
} kc_oc_maybe_object_t;

typedef void (^kc_object_enumeration_block_t)(__unsafe_unretained id object, __unsafe_unretained Class actualClass);

static kern_return_t reader(__unused task_t remote_task, vm_address_t remote_address, __unused vm_size_t size, void **local_memory) {
    *local_memory = (void *)remote_address;
    return KERN_SUCCESS;
}

static void range_callback(task_t task, void *context, unsigned type, vm_range_t *ranges, unsigned rangeCount) {
    if (!context) {
        return;
    }
    
    for (unsigned int i = 0; i < rangeCount; i++) {
        vm_range_t range = ranges[i];
        kc_oc_maybe_object_t *tryObject = (kc_oc_maybe_object_t *)range.address;
        Class tryClass = NULL;
#ifdef __arm64__
        // See http://www.sealiesoftware.com/blog/archive/2013/09/24/objc_explain_Non-pointer_isa.html
        extern uint64_t objc_debug_isa_class_mask WEAK_IMPORT_ATTRIBUTE;
        tryClass = (__bridge Class)((void *)((uint64_t)tryObject->isa & objc_debug_isa_class_mask));
#else
        tryClass = tryObject->isa;
#endif
        // If the class pointer matches one in our set of class pointers from the runtime, then we should have an object.
        if (CFSetContainsValue(registeredClasses, (__bridge const void *)(tryClass))) {
//            void(^block1)(id, Class) = (__bridge void(^)(id, Class))(*((void **)context));
            
            (*(kc_object_enumeration_block_t __unsafe_unretained *)context)((__bridge id)tryObject, tryClass);
        }
    }
}

@implementation KcHeapObjcManager

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static KcHeapObjcManager *shared;
    dispatch_once(&onceToken, ^{
        shared = [[KcHeapObjcManager alloc] init];
    });
    return shared;
}

+ (NSArray<id> *)instancesOfClass:(Class)cls {
    return [self instancesOfClasses:@[cls]];
}

/// 搜索这个class指针的所有对象
+ (NSArray<id> *)instancesOfClassAddress:(uintptr_t)classAddress {
    return [self instancesOfClass:(__bridge Class)((void *)classAddress)];
}

+ (NSArray<id> *)instancesOfClassWithName:(NSString *)className {
    const char *classNameCString = className.UTF8String;
    NSMutableArray *instances = [NSMutableArray new];
    [self enumerateLiveObjectsUsingBlock:^(__unsafe_unretained id object, __unsafe_unretained Class actualClass) {
        if (strcmp(classNameCString, class_getName(actualClass)) == 0) {
            // Note: objects of certain classes crash when retain is called.
            // It is up to the user to avoid tapping into instance lists for these classes.
            // Ex. OS_dispatch_queue_specific_queue
            // In the future, we could provide some kind of warning for classes that are known to be problematic.
            if (malloc_size((__bridge const void *)(object)) > 0) {
                [instances addObject:object];
            }
        }
    }];

    return instances;
}

+ (NSArray<id> *)instancesOfAllClassWithName:(NSString *)className {
    return [self instancesOfAllClass:NSClassFromString(className)];
}

+ (NSArray<id> *)instancesOfAllClass:(Class)cls {
    NSArray<Class> *classes = [self getAllSubclasses:cls includeSelf:true];
    return [self instancesOfClasses:classes];
}

+ (NSArray<id> *)subclassesOfClassWithName:(NSString *)className {
    NSArray<Class> *classes = [self getAllSubclasses:NSClassFromString(className) includeSelf:false];
    
    return [self instancesOfClasses:classes];
}

+ (NSArray<id> *)instancesOfClasses:(NSArray<Class> *)classes {
    return [self instancesOfClasses:classes filterBlock:nil];
}

+ (NSArray<id> *)instancesOfClasses:(NSArray<Class> *)classes filterBlock:(BOOL(^ _Nullable)(id objc))filterBlock {
    
    BOOL hasFilterBlock = filterBlock != nil;
    
    NSMutableArray *instances = [NSMutableArray new];
    [self enumerateLiveObjectsUsingBlock:^(__unsafe_unretained id object, __unsafe_unretained Class actualClass) {
        BOOL match = false;
        
        for (Class cls in classes) {
            if ([actualClass isEqual:cls]) {
                match = true;
                break;
            }
        }
        
        if (!match) {
            return;
        }
        
        // Note: objects of certain classes crash when retain is called.
        // It is up to the user to avoid tapping into instance lists for these classes.
        // Ex. OS_dispatch_queue_specific_queue
        // In the future, we could provide some kind of warning for classes that are known to be problematic.
        if (malloc_size((__bridge const void *)(object)) > 0) {
            if (hasFilterBlock && filterBlock(object)) {
                [instances addObject:object];
            } else {
                [instances addObject:object];
            }
        }
    }];
    
    return instances;
}

+ (void)enumerateLiveObjectsUsingBlock:(void (^)(__unsafe_unretained id object, __unsafe_unretained Class actualClass))block {
    if (!block) {
        return;
    }
    
    // Refresh the class list on every call in case classes are added to the runtime.
    [self updateRegisteredClasses];
    
    // Inspired by:
    // https://llvm.org/svn/llvm-project/lldb/tags/RELEASE_34/final/examples/darwin/heap_find/heap/heap_find.cpp
    // https://gist.github.com/samdmarshall/17f4e66b5e2e579fd396
    
    vm_address_t *zones = NULL;
    unsigned int zoneCount = 0;
    kern_return_t result = malloc_get_all_zones(TASK_NULL, reader, &zones, &zoneCount);
    
    if (result == KERN_SUCCESS) {
        for (unsigned int i = 0; i < zoneCount; i++) {
            malloc_zone_t *zone = (malloc_zone_t *)zones[i];
            malloc_introspection_t *introspection = zone->introspect;

            // This may explain why some zone functions are
            // sometimes invalid; perhaps not all zones support them?
            if (!introspection) {
                continue;
            }

            void (*lock_zone)(malloc_zone_t *zone)   = introspection->force_lock;
            void (*unlock_zone)(malloc_zone_t *zone) = introspection->force_unlock;

            // Callback has to unlock the zone so we freely allocate memory inside the given block
            void (^callback)(__unsafe_unretained id object, __unsafe_unretained Class actualClass) = ^(__unsafe_unretained id object, __unsafe_unretained Class actualClass) {
                unlock_zone(zone);
                block(object, actualClass);
                lock_zone(zone);
            };
            
            BOOL lockZoneValid = [KcMatchObjcInternal isValidReadableMemory:lock_zone];
            BOOL unlockZoneValid =  [KcMatchObjcInternal isValidReadableMemory:unlock_zone];

            // There is little documentation on when and why
            // any of these function pointers might be NULL
            // or garbage, so we resort to checking for NULL
            // and whether the pointer is readable
            if (introspection->enumerator && lockZoneValid && unlockZoneValid) {
                lock_zone(zone);
                introspection->enumerator(TASK_NULL, (void *)&callback, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)zone, reader, &range_callback);
                unlock_zone(zone);
            }
        }
    }
}

+ (void)updateRegisteredClasses {
    if (!registeredClasses) {
        registeredClasses = CFSetCreateMutable(NULL, 0, NULL);
    } else {
        CFSetRemoveAllValues(registeredClasses);
    }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        CFSetAddValue(registeredClasses, (__bridge const void *)(classes[i]));
    }
    free(classes);
}

+ (NSArray<Class> *)getAllSubclasses:(Class)cls includeSelf:(BOOL)includeSelf {
    if (!cls) return nil;
    
    Class *buffer = NULL;
    
    int count, size;
    do {
        count  = objc_getClassList(NULL, 0);
        buffer = (Class *)realloc(buffer, count * sizeof(*buffer));
        size   = objc_getClassList(buffer, count);
    } while (size != count);
    
    NSMutableArray *classes = [NSMutableArray new];
    if (includeSelf) {
        [classes addObject:cls];
    }
    
    for (int i = 0; i < count; i++) {
        Class candidate = buffer[i];
        Class superclass = candidate;
        while ((superclass = class_getSuperclass(superclass))) {
            if (superclass == cls) {
                [classes addObject:candidate];
                break;
            }
        }
    }
    
    free(buffer);
    return classes.copy;
}

+ (NSString *)safeClassNameForObject:(id)object {
    // Don't assume that we have an NSObject subclass
    if ([self safeObject:object respondsToSelector:@selector(class)]) {
        return NSStringFromClass([object class]);
    }

    return NSStringFromClass(object_getClass(object));
}

+ (BOOL)safeObject:(id)object respondsToSelector:(SEL)sel {
    // If we're given a class, we want to know if classes respond to this selector.
    // Similarly, if we're given an instance, we want to know if instances respond.
    BOOL isClass = object_isClass(object);
    Class cls = isClass ? object : object_getClass(object);
    // BOOL isMetaclass = class_isMetaClass(cls);
    
    if (isClass) {
        // In theory, this should also work for metaclasses...
        return class_getClassMethod(cls, sel) != nil;
    } else {
        return class_getInstanceMethod(cls, sel) != nil;
    }
}

/// 是否是堆对象
+ (BOOL)isHeapAddress:(uintptr_t)address {
    // 根据给定的内存指针确定分配该内存的内存区域（zone）
    return malloc_zone_from_ptr((void *)address) != nil;
}

/// 堆对象的信息
+ (nullable NSString *)heapObjcInfoWithAddress:(uintptr_t)address {
    void *ptr = (void *)address;
    if (malloc_zone_from_ptr(ptr)) {
        if ([KcMatchObjcInternal isObjcObject:ptr registeredClasses:nil]) {
            NSObject *objc = (__bridge NSObject *)ptr;
            
            if ([objc isKindOfClass:[CALayer class]]) {
                CALayer *layer = (CALayer *)objc;
                return [NSString stringWithFormat:@"layerDelegate: %@, layer: %@", layer.delegate, layer];
            } else if (object_isClass(objc)) {
                return [NSString stringWithFormat:@"class: %@", objc];
            } else {
                return [NSString stringWithFormat:@"objc: %@", objc];
            }
            
        } else {
            return [NSString stringWithFormat:@"%p heap pointer, (0x%zx bytes), zone: %p", ptr, (size_t)malloc_good_size((size_t)malloc_size(ptr)), (void*)malloc_zone_from_ptr(ptr)];
        }
    } else {
        return nil;
    }
}

/// 读取内存，获取堆上的信息
+ (nullable NSString *)heapObjcWithMemoryReadAddress:(uintptr_t)memory {
    void *address = *(void **)memory;
    return [self heapObjcInfoWithAddress:(uintptr_t)address];
}

@end
