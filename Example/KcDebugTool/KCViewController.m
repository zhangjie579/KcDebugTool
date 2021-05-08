//
//  KCViewController.m
//  KcDebugTool
//
//  Created by 张杰 on 04/12/2021.
//  Copyright (c) 2021 张杰. All rights reserved.
//

#import "KCViewController.h"
#import "KcDebugTool.h"
#import "fishhook.h"

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
    
    [self test1];
    
    [self.view addSubview:self.v1];
    self.v1.frame = CGRectMake(100, 100, 100, 100);
    
}

- (void)test1 {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    // -[UIGestureRecognizer _updateGestureForActiveEvents] ()

    [tool kc_hookWithObjc:UIGestureRecognizer.class selectorName:@"_updateGestureForActiveEvents" withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        
    }];
}

- (void)tapClick {
    NSLog(@"%s", _cmd);
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
