//
//  KcHookClassManager.h
//  NowLive
//
//  Created by samzjzhang on 2020/4/24.
//  Copyright © 2020 now. All rights reserved.
//  hook类方法管理者

#import <UIKit/UIKit.h>
#import "KcHookTool.h"
#import "KcHookModel.h"
#import "UIView+KcDebugTool.h"
#import "UIViewController+KcDebugTool.h"
#import "NSObject+KcRuntimeExtension.h"
#import "NSObject+KcMethodExtension.h"
#import "WKWebView+KcDebugTool.h"
#import "UICollectionView+KcDebugTool.h"
#import "UITableView+KcDebugTool.h"
#import "SRBlockStrongReferenceCollector.h"
#import "KcDetectLargerImageTool.h"
#import "UIWindow+KcDebugTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface KcHookClassManager : NSObject

/* 使用说明
 1. 把需要hook的class写到.m文件内的 `__attribute__((constructor)) void kc_hookDebugClass`方法内, 里面有例子
    * __attribute__((constructor)) 方法执行时机: load方法之后, main方法之前(也可以写在load方法内), 这样能够避免把这个调试工具引入到代码内
 2. hook方法: 使用NSObject+KcTest文件内的方法
    * 统计方法调用时间: 用的是KcAspectPositionAfter, 有问题就是: 打印的log是先内层方法最后才是外层方法
    * 获取调用方法: KcAspectPositionBefore (不需要调用时间, 用它即可)
 3.打印log
    * hook方法内部就已经打印了, 使用了前缀 kc--- 
 */

@end

NS_ASSUME_NONNULL_END
