//
//  NSMethodSignature+KcExtension.h
//  OCTest
//
//  Created by samzjzhang on 2020/7/21.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSMethodSignature (KcExtension)

- (BOOL)kc_isObjectArgumentAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
