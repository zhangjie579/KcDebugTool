//
//  KcMachOHelper+swiftTool.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/27.
//  swift相关

#import <KcDebugTool/KcMachOHelper.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcMachOHelper (swiftTool)

/// 查找swift符号
/// 原理: 遍历symbol table, 根据swift class name特定的特征
+ (void)findSwiftSymbolsWithBundlePath:(const char *)bundlePath
                                suffix:(const char *)suffix
                              callback:(void (^)(const void *symval, const char *symname, void *typeref, void *typeend))callback;

+ (void)findSwiftClassesWithBundlePath:(const char *)bundlePath
                              callback:(void(^)(Class cls))callback;

@end

NS_ASSUME_NONNULL_END
