//
//  NSMutableDictionary+KcExtension.m
//  KcDebugTool
//
//  Created by 张杰 on 2025/12/31.
//

#import "NSMutableDictionary+KcExtension.h"
#import "NSObject+KcRuntimeExtension.h"

@implementation NSMutableDictionary (KcExtension)

- (void)kchookMutableDictionary {
    NSMutableDictionary * dict = [NSMutableDictionary dictionary];
    Class dictClz = [dict class];
    
    [dictClz kc_hookSelectorName:@"addEntriesFromDictionary:" swizzleSelectorName:@"kchook_addEntriesFromDictionary"];
    [dictClz kc_hookSelectorName:@"removeAllObjects" swizzleSelectorName:@"kchook_removeAllObjects"];
    [dictClz kc_hookSelectorName:@"removeObjectsForKeys:" swizzleSelectorName:@"kchook_removeObjectsForKeys"];
    [dictClz kc_hookSelectorName:@"setDictionary:" swizzleSelectorName:@"kchook_setDictionary"];
    [dictClz kc_hookSelectorName:@"setObject:forKeyedSubscript:" swizzleSelectorName:@"kchook_setObject:forKeyedSubscript:"];
    [dictClz kc_hookSelectorName:@"setObject:forKey:" swizzleSelectorName:@"kchook_setObject:forKey:"];
    [dictClz kc_hookSelectorName:@"removeObjectForKey:" swizzleSelectorName:@"kchook_removeObjectForKey"];
}

- (void)kchook_addEntriesFromDictionary:(NSDictionary *)otherDictionary {
    [self kchook_addEntriesFromDictionary:otherDictionary];
}

- (void)kchook_removeAllObjects {
    [self kchook_removeAllObjects];
}

- (void)kchook_removeObjectsForKeys:(NSArray *)keyArray {
    [self kchook_removeObjectsForKeys:keyArray];
}

- (void)kchook_setDictionary:(NSDictionary *)otherDictionary {
    [self kchook_setDictionary:otherDictionary];
}

- (void)kchook_setObject:(id)obj forKeyedSubscript:(id<NSCopying>)key {
    [self kchook_setObject:obj forKeyedSubscript:key];
}

- (void)kchook_setObject:(id)anObject forKey:(id<NSCopying>)aKey {
    [self kchook_setObject:anObject forKey:aKey];
}

- (void)kchook_removeObjectForKey:(id)aKey {
    [self kchook_removeObjectForKey:aKey];
}

@end
