//
//  KCViewController.m
//  KcDebugTool
//
//  Created by 张杰 on 04/12/2021.
//  Copyright (c) 2021 张杰. All rights reserved.
//

#import "KCViewController.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/arch.h>
#import <mach-o/getsect.h>

#import <objc/message.h>
#import "fishhook.h"

#import "KcMachO.h"
#import "KcDebugTool_Example-Swift.h"

@import KcDebugTool;

@interface KCViewController ()

@property (nonatomic) UIView *v1;

@end

@implementation KCViewController

//static void (*orgi_NSLog)(NSString *format, ...);
//char *orgi_var = "wukaikai";
//extern char *global_var;
//void my_NSLog(NSString *format, ...) {
//    printf("hello %s\n", global_var);
//}
//int main123(int argc, const char * argv[]) {
//    @autoreleasepool {
//        // insert code here...
//        printf("hello %s\n", global_var);
//        struct rebinding rebind[2] = {
//            { "NSLog", my_NSLog, (void *)&orgi_NSLog },
//            { "global_var", &orgi_var, NULL }
//        };
//        rebind_symbols(rebind, 2);
//        NSLog(@"%s",global_var);
//    }
//    return 0;
//}


- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self.view addSubview:self.v1];
    self.v1.frame = CGRectMake(100, 100, 100, 100);
    
    NSArray<NSObject *> *objc = [KcMachOHelper globalObjects];
    
//    uintptr_t a = [KcMachOHelper defaultBaseAddressWithImageName:[NSBundle mainBundle].executablePath.UTF8String];
    
//    [KcMachO log_sectionDataWithImageName:@"KcDebugTool_Example"];
//    [KcMachOHelper log_symbolTableWithImageName:@"KcDebugTool_Example"];
    
//    NSString *path = [NSBundle bundleForClass:KcDebugTool.class].executablePath;
//    [KcMachOHelper findSwiftClassesWithBundlePath:path.UTF8String callback:^(Class  _Nonnull __unsafe_unretained cls) {
//        NSLog(@"%@", cls);
//    }];
    
//    [KcMachOHelper enumerateClassesInImageWithBlock:^(const char * _Nonnull path) {
//        if ([@(path) containsString:@"KcDebugTool_Example"]) {
//            NSLog(@"%s", path);
//        }
//    }];
    
    [self test1];
    
    NSLog(@"");
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    KCOneViewController *vc = [[KCOneViewController alloc] init];
    [self.navigationController pushViewController:vc animated:true];
}

- (void)test1 {
    NSLog(@"%s", _cmd);
}

- (void)tapClick {
    
}

+ (void)kc_test {
    NSLog(@"动态调用w ");
}

- (UIView *)v1 {
    if (!_v1) {
        _v1 = [[UIView alloc] init];
        _v1.backgroundColor = UIColor.orangeColor;
        [_v1 addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapClick)]];
    }
    return _v1;
}

@end
