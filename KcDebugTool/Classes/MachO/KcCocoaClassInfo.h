//
//  KcCocoaClassInfo.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/18.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 方法的信息
@interface KcCocoaClassImpInfo : NSObject

/// 全类名 eg: CocoaClassImpInfo or CocoaClassImpInfo(Tool)
@property (nonatomic, copy) NSString *fullClassName;

/// 类名 eg: CocoaClassImpInfo
@property (nonatomic, copy) NSString *className;

/// 函数名
@property (nonatomic, copy) NSString *methodName;

/// 是否是分类函数
@property (nonatomic, assign) BOOL isCategory;

/// 是否是类函数
@property (nonatomic, assign) BOOL isClassMethod;

/// 镜像路径
@property (nonatomic, copy) NSString *imagePath;

/// 符号名 -[CocoaClassImpInfo(Tool) test]
@property (nonatomic, copy) NSString *symbolName;

/// 根据IMP得到方法的信息, 通过dladdr获取方法的信息
/// 比如: test交换为kc_test, 通过imp获取的name: kc_test
+ (nullable KcCocoaClassImpInfo *)impInfoForImp:(IMP)imp;

@end

@interface KcCocoaClassInfo : NSObject

/// 是否为系统类 (非/Users/开头的库即视为系统库)
@property (nonatomic, assign) BOOL isSystemClass;

/// 类
@property (nonatomic) Class cls;

/// 类symbol
@property (nonatomic, copy) NSString *symbol;

/// 镜像
@property (nonatomic, copy) NSString *imageName;

/// 根据类符号获取类名
/// @param classSymbol 类符号
/// eg. @"OBJC_CLASS_$_TestClass"且TestClass存在 -> @"TestClass"
/// eg. @"_OBJC_$_CATEGORY_TestClass_$_Category"且TestClass存在 -> @"TestClass(Category)"
/// 如果类不存在，返回nil
+ (NSString *)classNameForClassSymbol:(NSString *)classSymbol;

/// className的原始class信息
/// 遍历镜像image, 看是否有对应类名
+ (KcCocoaClassInfo *)originClassInfoForClassName:(NSString *)className;

/// 从分类name -> class name
/// @param categoryClassName 分类名字
/// 如：@"TestClass(Category)" -> @"TestClass"
+ (NSString *)classNameForCategoryClassName:(NSString *)categoryClassName;

/// 是否是系统库
+ (BOOL)isSystemLibWithImagePath:(NSString *)imagePath;

@end

NS_ASSUME_NONNULL_END
