//
//  KcCocoaClassInfo.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/18.
//

#import "KcCocoaClassInfo.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>

@implementation KcCocoaClassInfo

/// className的原始class信息
/// 遍历镜像image, 看是否有对应类名
+ (KcCocoaClassInfo *)originClassInfoForClassName:(NSString *)className {
    // 1.处理可能分类名的情况
    className = [self classNameForCategoryClassName:className];
    
    // 2.dladdr获取符号信息
    // ViewController -> OBJC_CLASS_$_ViewController
    Class class = NSClassFromString(className);
    Dl_info info;
    int result = dladdr((__bridge const void *)(class), &info);
    const char *sym = info.dli_sname; // 符号名
    if (result == 0 || !sym || !className) {
        return nil;
    }
    
    // 3.遍历所有镜像
    __block KcCocoaClassInfo *classInfo;
    [self handleAllImagesWithAction:^BOOL(void *handle, const char *imageName, BOOL isSystemLib) {
        id classSym = (__bridge id)(dlsym(handle, sym));
        if (classSym) {
            Class class = [classSym class];
            if (class) { // 生成info
                classInfo = [[KcCocoaClassInfo alloc] init];
                classInfo.cls = class;
                classInfo.imageName = @(imageName);
                classInfo.symbol = [NSString stringWithUTF8String:sym];
                NSBundle *bundle = [NSBundle bundleForClass:class];
                // 非/Users/开头的库即视为系统库
                classInfo.isSystemClass = [self isSystemLibWithImagePath:bundle.bundlePath];
                return YES;
            }
        }
        return NO;
    }];
    
    return classInfo;
}

/// 根据类符号获取类名
/// @param classSymbol 类符号
/// eg. @"OBJC_CLASS_$_TestClass"且TestClass存在 -> @"TestClass"
/// eg. @"_OBJC_$_CATEGORY_TestClass_$_Category"且TestClass存在 -> @"TestClass(Category)"
/// 如果类不存在，返回nil
+ (NSString *)classNameForClassSymbol:(NSString *)classSymbol {
    if (!classSymbol) {
        return classSymbol;
    }
    // OBJC_CLASS_$_TestClass -> TestClass
    if ([classSymbol hasPrefix:@"OBJC_CLASS_$_"]) {
        NSString *className = [classSymbol stringByReplacingOccurrencesOfString:@"OBJC_CLASS_$_" withString:@""];
        if (NSClassFromString(className)) {
            return className;
        }
    }
    
    // _OBJC_$_CATEGORY_TestClass_$_Category -> TestClass(Category)
    if ([classSymbol hasPrefix:@"_OBJC_$_CATEGORY_"]) {
        classSymbol = [classSymbol stringByReplacingOccurrencesOfString:@"_OBJC_$_CATEGORY_" withString:@""];
        NSArray<NSString *> *results = [classSymbol componentsSeparatedByString:@"_$_"];
        if (results.count == 2) {
            NSString *className = results[0];
            NSString *categoryName = results[1];
            if (NSClassFromString(className)) {
                return [NSString stringWithFormat:@"%@(%@)", className, categoryName];
            }
        }
    }
    
    __block NSString *className;
    [self handleAllImagesWithAction:^BOOL(void *handle, const char *imageName, BOOL isSystemLib) {
        id classSym = (__bridge id)(dlsym(handle, classSymbol.UTF8String));
        Class orginClass = [classSym class];
        if (orginClass) {
            className = NSStringFromClass(orginClass);
            return YES;
        }
        return NO;
    }];
       
    return className;
}

/// 处理所有镜像
/// @param action 处理逻辑放在action，如果需要退出循环，直接在block内return YES.
+ (void)handleAllImagesWithAction:(BOOL(^)(void *handle, const char *imageName, BOOL isSystemLib))action {
    uint32_t count = _dyld_image_count();
    
    for (uint32_t i = 0; i < count; i++) {
        const char *imageName = _dyld_get_image_name(i);
        void *dHandle = dlopen(imageName, RTLD_NOW);
        if (action && imageName) {
            BOOL shouldStop = action(dHandle,
                                     imageName,
                                     [self isSystemLibWithImagePath:[NSString stringWithUTF8String:imageName]]);
            dlclose(dHandle);
            if (shouldStop) { // 停止
                return;
            }
        } else {
            dlclose(dHandle);
        }
    }
}

/// 从分类name -> class name
/// @param categoryClassName 分类名字
/// 如：@"TestClass(Category)" -> @"TestClass"
+ (NSString *)classNameForCategoryClassName:(NSString *)categoryClassName {
    // NSObject(Test)
    NSRange separateRange = [categoryClassName rangeOfString:@"("];
    if (separateRange.location != NSNotFound) {
        return [categoryClassName substringToIndex:separateRange.location];
    }
    
    return categoryClassName ?: @"";
}

/// 是否是系统库
+ (BOOL)isSystemLibWithImagePath:(NSString *)imagePath {
    if (!imagePath) {
        return false;
    }
    
    // 模拟器 非/Users/和非/Volumes/开头的库即视为系统库
    // 真机 非/private/var/containers/Bundle/Application/ 或者 /var/containers/Bundle/Application/开头的库即视为系统库
    return ![imagePath hasPrefix:@"/Users/"]
            && ![imagePath hasPrefix:@"/Volumes/"]
            && ![imagePath hasPrefix:@"/private/var/containers/Bundle/Application/"]
            && ![imagePath hasPrefix:@"/var/containers/Bundle/Application/"];
}

@end

@implementation KcCocoaClassImpInfo

/// 根据IMP得到方法的信息, 通过dladdr获取方法的信息
/// 比如: test交换为kc_test, 通过imp获取的name: kc_test
+ (nullable KcCocoaClassImpInfo *)impInfoForImp:(IMP)imp {
    if (!imp) {
        return nil;
    }
    Dl_info info;
    int result = dladdr(imp, &info);
    // 比如: -[CocoaClassImpInfo impInfoForImp:]
    if (result == 0 || !info.dli_sname) {
        return nil;
    }
    
    NSString *sname = [self stringWithUTF8String:info.dli_sname];
    if (([sname hasPrefix:@"+"] || [sname hasPrefix:@"-"])
        && [sname containsString:@"["]
        && [sname hasSuffix:@"]"]
        && [sname containsString:@" "]) { // 只处理oc方法
        NSRange spaceRange = [sname rangeOfString:@" "
                                          options:NSBackwardsSearch
                                            range:NSMakeRange(0, sname.length)];
        NSRange startRange = NSMakeRange(1, 1); // @"["
        NSRange endRange = NSMakeRange(sname.length - 1, 1); // @"]"
        if (spaceRange.location != NSNotFound
            && startRange.location != NSNotFound
            && spaceRange.location > startRange.location
            && spaceRange.location != NSNotFound) {
            
            KcCocoaClassImpInfo *impInfo = [KcCocoaClassImpInfo new];
            NSInteger location = startRange.location + startRange.length;
            NSString *fullClassName = [sname substringWithRange:NSMakeRange(location, spaceRange.location - location)];
            impInfo.fullClassName = fullClassName;
            impInfo.className = [self classNameForCategoryClassName:fullClassName];
            NSString *selName = [sname substringWithRange:NSMakeRange(spaceRange.location + 1, endRange.location - (spaceRange.location + 1))];
            impInfo.methodName = selName;
            impInfo.isCategory = [fullClassName hasSuffix:@")"];
            impInfo.isClassMethod = [sname hasPrefix:@"+"];
            impInfo.imagePath = [self stringWithUTF8String:info.dli_fname];
            impInfo.symbolName = sname;
            
            return impInfo;
        }
    }
    
    return nil;
}

/// 从分类name -> class name
+ (NSString *)classNameForCategoryClassName:(NSString *)categoryClassName {
    // NSObject(Test)
    NSRange separateRange = [categoryClassName rangeOfString:@"("];
    if (separateRange.location != NSNotFound) {
        return [categoryClassName substringToIndex:separateRange.location];
    }
    
    return categoryClassName ?: @"";
}

- (NSString *)description {
    return [NSString stringWithFormat:@"symbolName: %@", self.symbolName];
}

#pragma mark - tool

/// 加入容差处理
+ (NSString *)stringWithUTF8String:(const char *)nullableCString {
    if (!nullableCString || strlen(nullableCString) == 0) {
        return @"";
    }
    return [NSString stringWithUTF8String:nullableCString];
}

@end
