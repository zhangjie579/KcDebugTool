//
//  KcDebugView.m
//  OCTest
//
//  Created by samzjzhang on 2020/6/16.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "KcDebugView.h"

@implementation KcDebugView

- (void)setFrame:(CGRect)frame {
    
//    NSLog(@"aa--- %@", NSStringFromCGRect(frame));
    
    [super setFrame:frame];
}

@end

@implementation KcDebugKVOTool

+ (instancetype)shared {
    static dispatch_once_t onceToken;
    static KcDebugKVOTool *manager;
    dispatch_once(&onceToken, ^{
        manager = [[KcDebugKVOTool alloc] init];
    });
    return manager;
}

+ (void)addObserverWithObject:(id)object
                   forKeyPath:(NSString *)keyPath
                      options:(NSKeyValueObservingOptions)options
                      context:(void *)context {
    [object addObserver:[self shared] forKeyPath:keyPath options:options context:context];
}

- (void)addObserverWithObject:(id)object forKeyPath:(NSString *)keyPath {
    [self addObserverWithObject:object forKeyPath:keyPath options:NSKeyValueObservingOptionNew context:nil];
}

- (void)addObserverWithObject:(id)object
                   forKeyPath:(NSString *)keyPath
                      options:(NSKeyValueObservingOptions)options {
    [self addObserverWithObject:object forKeyPath:keyPath options:options context:nil];
}

- (void)addObserverWithObject:(id)object
                   forKeyPath:(NSString *)keyPath
                      options:(NSKeyValueObservingOptions)options
                      context:(void *)context {
    [object addObserver:self forKeyPath:keyPath options:options context:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    id newValue = change[NSKeyValueChangeNewKey];
    NSLog(@"kc--- KVO keyPath: %@, object: %@, newValue: %@, change: %@", keyPath, object, newValue, change);
    if (self.blockObserver) {
        self.blockObserver(keyPath, object, change);
    }
}

@end
