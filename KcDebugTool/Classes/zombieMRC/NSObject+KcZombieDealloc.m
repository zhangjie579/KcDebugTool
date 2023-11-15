//
//  NSObject+KcZombieDealloc.m
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/18.
//

#import "NSObject+KcZombieDealloc.h"
#import <objc/message.h>
#import <malloc/malloc.h>
#import "KcZombieManager.h"
#import "KC_NSZombie_Objc.h"

@implementation NSObject (KcZombieDealloc)

- (void)kc_zombie_dealloc {
    const char *className = object_getClassName(self);
    
    // 对于私有类的话, 直接过来
    if (strncmp(className, "_", 1) == 0 || strncmp(className, "OS", 2) == 0) {
        [self kc_origin_dealloc];
        return;
    }
    
    void *p = (__bridge void *)self;
    
    size_t memSize = malloc_size(p);
    if (memSize < [KC_NSZombie_Objc zombieInstanceSize]) { // 有足够的空间才覆盖
        [self kc_origin_dealloc];
        return;
    }
    
    NSArray<NSString *> *blackZombieClassNames = [KcZombieManager.sharedInstance blackZombieClassNames];
    
    // 全部都不free
    if (blackZombieClassNames == nil || blackZombieClassNames.count == 0) {
        [self kc_zombie_custom_dealloc];
        return;
    }
    
    NSString *clsname = @(className);
    if ([blackZombieClassNames containsObject:clsname]) {
        [self kc_zombie_custom_dealloc];
        return;
    }
    
    // 走原始的
    [self kc_origin_dealloc];
}

- (void)kc_zombie_custom_dealloc {
    // 会处理关联对象_object_remove_assocations、object_cxxDestruct
    objc_destructInstance(self);
    
    void *p = (__bridge void *)self;
    
    size_t memSize = malloc_size(p);
    
    ///填充0x55能稍微提升一些crash率 👍🏻
    memset(p, 0x55, memSize); // 将对象的内存区域都填入为0x55, 这样只要访问就会crash
//    memset(p, 0x00, [DDZombie zombieInstanceSize]); // 由于会修改isa为DDZombie, 将DDZombie所需的内存区域重置为0
    
    // 修改isa
    object_setClass(self, objc_getClass("KC_NSZombie_Objc"));
    
    // 通常野指针发生是在对象dealloc后10s左右, 过了10s后, 将内存释放, 避免长期占用
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        free(self);
    });
}

- (void)kc_origin_dealloc {
    objc_destructInstance(self);
    free(self);
}

@end
