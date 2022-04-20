////  NSObject+DDZombieDetector.m
//  DDZombieDetector
//
//  Created by Alex Ting on 2018/7/14.
//  Copyright © 2018年 Alex. All rights reserved.
//

#import "NSObject+DDZombieDetector.h"
#import "DDZombieMonitor+Private.h"
#import "DDZombieMonitor.h"

@implementation NSObject (DDZombieDetector)

/// 原始的dealloc
-(void)hy_originalDealloc {
    //placeholder for original dealloc
}

/// new dealloc
-(void)hy_newDealloc {
    [[DDZombieMonitor sharedInstance] newDealloc:self];
}

@end
