//
//  NSObject+zombieDealloc.m
//  FortunePlat
//
//  Created by sgcy on 2018/7/26.
//  Copyright © 2018年 Tencent. All rights reserved.
//
#import <objc/runtime.h>
#import <Foundation/NSObjCRuntime.h>
#import <malloc/malloc.h>

//#import "NSObject+zombieDealloc.h"


#define ZOMBIE_PREFIX "_NSZombie_"

NS_ROOT_CLASS
@interface _NSZombie_ {
    Class isa;
}

@end

@implementation _NSZombie_

+ (void)initialize
{
    
}

@end



@implementation NSObject(zombieDealloc)

//- (void)dealloc
//{
//    const char *className = object_getClassName(self);
//    char *zombieClassName = NULL;
//    do {
//        if (asprintf(&zombieClassName, "%s%s", ZOMBIE_PREFIX, className) == -1)
//        {
//            break;
//        }
//        
//        Class zombieClass = objc_getClass(zombieClassName);
//        
//        if (zombieClass == Nil)
//        {
//            // 创建一个类的副本
//            // 主要作用是允许在运行时创建一个与现有类具有相同实例变量、属性、方法等定义的类。
//            zombieClass = objc_duplicateClass(objc_getClass(ZOMBIE_PREFIX), zombieClassName, 0);
//        }
//        
//        if (zombieClass == Nil)
//        {
//            break;
//        }
//        
//        objc_destructInstance(self);
//        
//        void *p = (__bridge void *)self;
//        
//        size_t memSize = malloc_size(p);
////        if (memSize < [DDZombie zombieInstanceSize]) { // 有足够的空间才覆盖
////            [obj performSelector:@selector(hy_originalDealloc)];
////            return;
////        }
//        
//        ///填充0x55能稍微提升一些crash率 👍🏻
//        memset(p, 0x55, memSize); // 将对象的内存区域都填入为0x55, 这样只要访问就会crash
////        memset(p, 0x00, [DDZombie zombieInstanceSize]); // 由于会修改isa为DDZombie, 将DDZombie所需的内存区域重置为0
//        
//        object_setClass(self, zombieClass);
//        
//    } while (0);
//    
//    if (zombieClassName != NULL)
//    {
//        free(zombieClassName);
//    }
//}

@end
