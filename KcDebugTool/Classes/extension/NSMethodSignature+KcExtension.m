//
//  NSMethodSignature+KcExtension.m
//  OCTest
//
//  Created by samzjzhang on 2020/7/21.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "NSMethodSignature+KcExtension.h"
#import <objc/message.h>

@implementation NSMethodSignature (KcExtension)

- (BOOL)kc_isObjectArgumentAtIndex:(NSUInteger)index {
    const char *argType = [self getArgumentTypeAtIndex:index];
    // Skip const type qualifier.
    if (argType[0] == _C_CONST) argType++;

    // 1.id、class
    if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
        return true;
    // 2.sel
    } else if (strcmp(argType, @encode(SEL)) == 0) {
        return false;
    // 3.class
    } else if (strcmp(argType, @encode(Class)) == 0) {
        return true;
    } else {
        return false;
    }
}


@end
