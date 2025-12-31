//
//  NSMutableArray+KcExtension.m
//  KcDebugTool
//
//  Created by 张杰 on 2025/12/31.
//

#import "NSMutableArray+KcExtension.h"
#import "NSObject+KcRuntimeExtension.h"

@implementation NSMutableArray (KcExtension)

+ (void)kcSwizzleMutableArray {
    NSMutableArray * array = [NSMutableArray array];
    Class arrClz = [array class];
    
    [arrClz kc_hookSelectorName:@"setObject:atIndexedSubscript:"
            swizzleSelectorName:@"kchook_setObject:atIndexedSubscript:"];
    [arrClz kc_hookSelectorName:@"removeObjectAtIndex:"
            swizzleSelectorName:@"kchook_removeObjectAtIndex:"];
    [arrClz kc_hookSelectorName:@"insertObject:atIndex:"
            swizzleSelectorName:@"kchook_insertObject:atIndex:"];
    [arrClz kc_hookSelectorName:@"addObject:"
            swizzleSelectorName:@"kchook_addObject:"];
    [arrClz kc_hookSelectorName:@"replaceObjectAtIndex:withObject:"
            swizzleSelectorName:@"kchook_replaceObjectAtIndex:withObject:"];
    [arrClz kc_hookSelectorName:@"addObjectsFromArray:"
            swizzleSelectorName:@"kchook_addObjectsFromArray:"];
    [arrClz kc_hookSelectorName:@"removeAllObjects"
            swizzleSelectorName:@"kchook_removeAllObjects"];
    [arrClz kc_hookSelectorName:@"removeObject:"
            swizzleSelectorName:@"kchook_removeObject"];
    [arrClz kc_hookSelectorName:@"removeObjectsInRange:"
            swizzleSelectorName:@"kchook_removeObjectsInRange"];
//    [arrClz kc_hookSelectorName:@"removeObjectIdenticalTo:"
//            swizzleSelectorName:@"kchook_removeObjectIdenticalTo"];
//    [arrClz kc_hookSelectorName:@"removeObjectIdenticalTo:inRange:"
//            swizzleSelectorName:@"kchook_removeObjectIdenticalTo:inRange"];
}

- (void)kchook_setObject:(id)object atIndexedSubscript:(NSUInteger)index {
    [self kchook_setObject:object atIndexedSubscript:index];
    
    [self kcdebug_handle];
}

- (void)kchook_removeObjectAtIndex:(NSUInteger)index {
    [self kchook_removeObjectAtIndex:index];
    
    [self kcdebug_handle];
}

- (void)kchook_insertObject:(id)object atIndex:(NSUInteger)index {
    [self kchook_insertObject:object atIndex:index];
    
    [self kcdebug_handle];
}

- (void)kchook_addObject:(id)object {
    [self kchook_addObject:object];
    
    [self kcdebug_handle];
}

- (void)kchook_replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject {
    [self kchook_replaceObjectAtIndex:index withObject:anObject];
    
    [self kcdebug_handle];
}

- (void)kchook_addObjectsFromArray:(NSArray<id> *)otherArray {
    [self kchook_addObjectsFromArray:otherArray];
    
    [self kcdebug_handle];
}

//- (void)exchangeObjectAtIndex:(NSUInteger)idx1 withObjectAtIndex:(NSUInteger)idx2;
- (void)kchook_removeAllObjects {
    [self kchook_removeAllObjects];
    
    [self kcdebug_handle];
}

- (void)kchook_removeObject:(id)anObject inRange:(NSRange)range {
    [self kchook_removeObject:anObject inRange:range];
    
    [self kcdebug_handle];
}

- (void)kchook_removeObject:(id)anObject {
    [self kchook_removeObject:anObject];
    
    [self kcdebug_handle];
}

//- (void)removeObjectIdenticalTo:(ObjectType)anObject inRange:(NSRange)range;
//- (void)removeObjectIdenticalTo:(ObjectType)anObject;
//- (void)removeObjectsFromIndices:(NSUInteger *)indices numIndices:(NSUInteger)cnt API_DEPRECATED("Not supported", macos(10.0,10.6), ios(2.0,4.0), watchos(2.0,2.0), tvos(9.0,9.0));
//- (void)removeObjectsInArray:(NSArray<ObjectType> *)otherArray;
//- (void)removeObjectsInRange:(NSRange)range;
//- (void)replaceObjectsInRange:(NSRange)range withObjectsFromArray:(NSArray<ObjectType> *)otherArray range:(NSRange)otherRange;
//- (void)replaceObjectsInRange:(NSRange)range withObjectsFromArray:(NSArray<ObjectType> *)otherArray;
//- (void)setArray:(NSArray<ObjectType> *)otherArray;
//- (void)sortUsingFunction:(NSInteger (NS_NOESCAPE *)(ObjectType,  ObjectType, void * _Nullable))compare context:(nullable void *)context;
//- (void)sortUsingSelector:(SEL)comparator;

//- (void)insertObjects:(NSArray<ObjectType> *)objects atIndexes:(NSIndexSet *)indexes;
//- (void)removeObjectsAtIndexes:(NSIndexSet *)indexes;
//- (void)replaceObjectsAtIndexes:(NSIndexSet *)indexes withObjects:(NSArray<ObjectType> *)objects;

- (void)kcdebug_handle {
    
}

@end
