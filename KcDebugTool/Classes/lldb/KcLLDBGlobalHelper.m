//
//  KcLLDBGlobalHelper.m
//  Pods
//
//  Created by 张杰 on 2023/9/6.
//

#import "KcLLDBGlobalHelper.h"
#import <objc/message.h>

@implementation KcLLDBGlobalHelper

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static KcLLDBGlobalHelper *shared;
    dispatch_once(&onceToken, ^{
        shared = [[KcLLDBGlobalHelper alloc] init];
    });
    return shared;
}

/// 根据地址查询出方法名
- (NSArray<NSString *> *)lookupWithAddresses:(NSArray<NSNumber *> *)addresses {
    
    NSMutableArray<NSString *> *symbols = [[NSMutableArray alloc] init];
    
    for (NSNumber *address in addresses) {
        NSString *_Nullable symbol = [self lookupWithAddress:address.integerValue];
        [symbols addObject:[NSString stringWithFormat:@"%@: %@", address, symbol ?: @""]];
    }
    
    return symbols;
}

/// 根据地址查询出方法名
- (nullable NSString *)lookupWithAddress:(NSInteger)address {
    
    NSNumber *numberAddress = [NSNumber numberWithInteger:address];
    
    if (self.addressMethodNameDictionary != nil) {
        return self.addressMethodNameDictionary[numberAddress];
    }
    
    self.addressMethodNameDictionary = [[NSMutableDictionary alloc] init];
    
    unsigned int outCount = outCount;
    Class *classList = objc_copyClassList(&outCount);
    for (int k = 0; k < outCount; k++) {
        Class cls = classList[k];
        
//        if (!(Class)class_getSuperclass(cls)) {
//            continue;
//        }
        unsigned int methCount = 0;
        Method *methods = class_copyMethodList(cls, &methCount);
        for (int j = 0; j < methCount; j++) {
            Method meth = methods[j];
            uintptr_t implementation = (uintptr_t)method_getImplementation(meth);
            NSString *methodName = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(method_getName(meth))];
            self.addressMethodNameDictionary[@(implementation)] = methodName;
        }
        
        free(methods);
        methods = nil;
        
        unsigned int classMethCount = 0;
        
        Method *classMethods = class_copyMethodList(objc_getMetaClass(class_getName(cls)), &classMethCount);
        for (int j = 0; j < classMethCount; j++) {
            Method meth = classMethods[j];
            uintptr_t implementation = (uintptr_t)method_getImplementation(meth);
            NSString *methodName = [NSString stringWithFormat:@"+[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(method_getName(meth))];
            self.addressMethodNameDictionary[@(implementation)] = methodName;
        }
        
        free(classMethods);
        classMethods = nil;
    }
    
    free(classList);
    classList = nil;
    
    return self.addressMethodNameDictionary[numberAddress];
}

@end
