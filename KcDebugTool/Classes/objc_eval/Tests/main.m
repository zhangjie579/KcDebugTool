#import "../KCObjCEval.h"
#import <dlfcn.h>

@interface KCEvalFixture : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) KCEvalFixture *next;
@property (nonatomic) NSInteger count;
@property (nonatomic, readonly) NSString *computed;
- (NSString *)join:(NSString *)left right:(NSString *)right;
- (KCEvalFixture *)child;
- (void)clear;
@end

@implementation KCEvalFixture
- (NSString *)computed { return [@"computed:" stringByAppendingString:self.name ?: @""]; }
- (NSString *)join:(NSString *)left right:(NSString *)right { return [left stringByAppendingString:right]; }
- (KCEvalFixture *)child { return self; }
- (void)clear { self.name = nil; }
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); abort(); }
}

int main(void) {
    @autoreleasepool {
        KCEvalFixture *object = [KCEvalFixture new];
        object.name = @"Ada";
        NSDictionary *variables = @{@"self": object};
        KCObjCEvalResult *r = [KCObjCEval evaluate:@"[[self child] join:@\"A\" right:@\"B\"]" variables:variables];
        Check(r.success && [r.value isEqual:@"AB"], @"nested selector arguments");
        r = [KCObjCEval evaluate:@"self.computed" variables:variables];
        Check(r.success && [r.value isEqual:@"computed:Ada"], @"computed property");
        r = [KCObjCEval evaluate:@"[self join:@\"A\" right:@\"B\"].length" variables:variables];
        Check(r.success && [r.value isEqual:@2], @"chained scalar getter");
        r = [KCObjCEval evaluate:@"[self join:Hello right:\" World\"]" variables:variables];
        Check(r.success && [r.value isEqual:@"Hello World"], @"bare and quoted string arguments");
        NSString *address = [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)(__bridge void *)object];
        r = [KCObjCEval evaluate:@"[self child].name" variables:@{@"self": address}];
        Check(r.success && [r.value isEqual:@"Ada"], @"address replacement");
        r = [KCObjCEval evaluate:[NSString stringWithFormat:@"[%@ child].name", address]];
        Check(r.success && [r.value isEqual:@"Ada"], @"address receiver");
        KCEvalFixture *nested = [KCEvalFixture new];
        object.next = nested;
        r = [KCObjCEval evaluate:[NSString stringWithFormat:@"%@.next.name = xx", address]];
        Check(r.success && [r.value isEqual:@"xx"] && [nested.name isEqual:@"xx"],
              [@"nested address property assignment: " stringByAppendingString:r.displayText]);
        r = [KCObjCEval evaluate:@"self.next.count = @42" variables:variables];
        Check(r.success && [r.value isEqual:@42] && nested.count == 42, @"scalar property assignment");
        r = [KCObjCEval evaluate:@"self.next.name = \"New name\"; self.next.name" variables:variables];
        Check(r.success && [r.value isEqual:@"New name"] && [nested.name isEqual:@"New name"],
              @"assignment and subsequent getter");
        r = [KCObjCEval evaluate:@"self.next.name = nil" variables:variables];
        Check(r.success && r.hasReturnValue && r.value == nil && nested.name == nil, @"nil assignment");
        r = [KCObjCEval evaluate:@"self.computed = xx" variables:variables];
        Check(!r.success && r.errorMessage.length > 0, @"read-only property assignment fails");
        NSError *error = nil;
        BOOL added = [KCObjCEval injectSelector:@selector(kcEcho:) intoClass:KCEvalFixture.class classMethod:NO
                                implementation:^id(id target, NSArray *args) { return args[0]; } error:&error];
        Check(added && !error, @"dynamic method installation");
        r = [KCObjCEval evaluate:@"[self kcEcho:@\"OK\"]" variables:variables];
        Check(r.success && [r.value isEqual:@"OK"], @"dynamic method call");
        added = [KCObjCEval injectSelector:@selector(kcClassEcho:) intoClass:KCEvalFixture.class classMethod:YES
                          implementation:^id(id target, NSArray *args) { return args[0]; } error:&error];
        Check(added, @"dynamic class method installation");
        r = [KCObjCEval evaluate:@"[KCEvalFixture kcClassEcho:@{ @\"list\": @[@1, @2] }]"];
        Check(r.success && [r.value isKindOfClass:NSDictionary.class] && [r.value[@"list"] count] == 2,
              @"class method and collection literals");
        r = [KCObjCEval evaluate:@"[self clear]" variables:variables];
        Check(r.success && !r.hasReturnValue, @"void result");
        r = [KCObjCEval evaluate:@"[self clear]; @7" variables:variables];
        Check(r.success && r.hasReturnValue && [r.value isEqual:@7], @"last statement result");
        r = [KCObjCEval evaluate:@"self.name" variables:variables];
        Check(r.success && r.hasReturnValue && r.value == nil, @"nil result");
        r = [KCObjCEval evaluate:@"[self missing]" variables:variables];
        Check(!r.success && r.errorMessage.length > 0, @"structured failure");
        r = [KCObjCEval evaluate:@"[0x1000 missing]"];
        Check(!r.success && r.errorMessage.length > 0, @"invalid address rejection");
        void *swiftLibrary = dlopen("/private/tmp/libKCSwiftFixture.dylib", RTLD_NOW | RTLD_GLOBAL);
        Check(swiftLibrary != NULL, @"load pure Swift fixture");
        r = [KCObjCEval evaluate:@"[KCSwiftFixture.KCSwiftNativeFixture add:@3 b:@4]"];
        Check(r.success && [r.value isEqual:@7], [@"pure Swift static method: " stringByAppendingString:r.displayText]);
        r = [KCObjCEval evaluate:@"KCSwiftFixture.KCSwiftNativeFixture.count"];
        Check(r.success && [r.value isEqual:@7], @"pure Swift computed static property");
        r = [KCObjCEval evaluate:@"[KCSwiftFixture.KCSwiftNativeFixture make]"];
        Check(r.success && r.value != nil, @"pure Swift class object return");
        id swiftObject = r.value;
        r = [KCObjCEval evaluate:@"[[KCSwiftFixture.KCSwiftNativeFixture make] multiply:@4]"];
        Check(r.success && [r.value isEqual:@12], [@"pure Swift instance chain: " stringByAppendingString:r.displayText]);
        r = [KCObjCEval evaluate:@"[[KCSwiftFixture.KCSwiftNativeFixture make] multiply:4]"];
        Check(r.success && [r.value isEqual:@12], @"unboxed integer literal");
        r = [KCObjCEval evaluate:@"[KCSwiftFixture.KCSwiftNativeFixture greet:Alice]"];
        Check(r.success && [r.value isEqual:@"Hello, Alice"], [@"Swift bare String: " stringByAppendingString:r.displayText]);
        r = [KCObjCEval evaluate:@"[[KCSwiftFixture.KCSwiftNativeFixture make] echo:\"hello world\"]"];
        Check(r.success && [r.value isEqual:@"hello world"], @"Swift quoted String");
        NSString *longText = @"你好，Swift String 参数与返回值的长文本";
        for (NSUInteger i = 0; i < 20; i++) {
            r = [KCObjCEval evaluate:@"[[KCSwiftFixture.KCSwiftNativeFixture make] echo:\"你好，Swift String 参数与返回值的长文本\"]"];
            Check(r.success && [r.value isEqual:longText], @"Swift long Unicode String ownership");
        }
        r = [KCObjCEval evaluate:@"[KCSwiftFixture.KCSwiftNativeFixture make].factor"];
        Check(r.success && [r.value isEqual:@3], @"pure Swift instance property");
        NSString *swiftAddress = [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)(__bridge void *)swiftObject];
        r = [KCObjCEval evaluate:@"[self multiply:@5]" variables:@{@"self": swiftAddress}];
        Check(r.success && [r.value isEqual:@15], [@"pure Swift address receiver: " stringByAppendingString:r.displayText]);
        NSLog(@"KCObjCEval tests passed");
    }
    return 0;
}
