//
//  KcZombieManager.m
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/18.
//

#import "KcZombieManager.h"
#import <objc/message.h>

@interface KcZombieManager ()

@property (nonatomic, assign) BOOL started;

@end

@implementation KcZombieManager

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static KcZombieManager *s;
    dispatch_once(&onceToken, ^{
        s = [[KcZombieManager alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        self.blackZombieClassNames = [[NSMutableArray alloc] init];
        self.started = false;
    }
    return self;
}

- (void)startWithZombieClassNames:(nullable NSArray<NSString *> *)classNames {
    if (classNames.count > 0) {
        [self.blackZombieClassNames addObjectsFromArray:classNames];
    }
    
    // 方案的缺点: 只能监听NSObject对象, 非NSObject不能处理
    if (!self.started) {
        replaceSelectorWithSelector([NSObject class], NSSelectorFromString(@"dealloc"), NSSelectorFromString(@"kc_zombie_dealloc"));
        self.started = true;
    }
    
}

static void replaceSelectorWithSelector(Class aCls,
                                        SEL selector,
                                        SEL replacementSelector) {
    Method replacementSelectorMethod = class_getInstanceMethod(aCls, replacementSelector);
    Class classEntityToEdit = aCls;
    class_replaceMethod(classEntityToEdit,
                        selector,
                        method_getImplementation(replacementSelectorMethod),
                        method_getTypeEncoding(replacementSelectorMethod));
}


@end
