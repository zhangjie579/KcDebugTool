//
//  KcClassDump.h
//  objc-001
//
//  Created by 张杰 on 2021/5/13.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcClassDump : NSObject

+ (void)dumpClass:(Class)aClass;

@end

NS_ASSUME_NONNULL_END
