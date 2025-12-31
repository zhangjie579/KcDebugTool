//
//  NSMutableArray+KcExtension.h
//  KcDebugTool
//
//  Created by 张杰 on 2025/12/31.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSMutableArray (KcExtension)

+ (void)kcSwizzleMutableArray;

- (void)kchook_setObject:(id)object atIndexedSubscript:(NSUInteger)index;
- (void)kchook_removeObjectAtIndex:(NSUInteger)index;
- (void)kchook_insertObject:(id)object atIndex:(NSUInteger)index;
- (void)kchook_addObject:(id)object;

@end

NS_ASSUME_NONNULL_END
