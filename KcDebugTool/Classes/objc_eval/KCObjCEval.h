#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A deliberately small Objective-C expression evaluator for debugging.
/// Swift @objc members use the Objective-C runtime. Supported native Swift
/// symbols use a separate Mach-O/arm64 ABI path (see README for type limits).
@interface KCObjCEvalResult : NSObject
@property (nonatomic, readonly) BOOL success;
@property (nonatomic, readonly) BOOL hasReturnValue;
@property (nonatomic, strong, readonly, nullable) id value;
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;
@property (nonatomic, copy, readonly) NSString *displayText;
@end

typedef id _Nullable (^KCObjCEvalMethodBlock)(id target, NSArray *arguments);

@interface KCObjCEval : NSObject
/// Values replace identifiers in the expression. A string such as @"0x1234"
/// is resolved as a live object address when used as a receiver or object argument.
+ (KCObjCEvalResult *)evaluate:(NSString *)expression;
+ (KCObjCEvalResult *)evaluate:(NSString *)expression variables:(nullable NSDictionary<NSString *, id> *)variables;

/// Installs an object-argument/object-return method (0...4 arguments) in the runtime.
/// For class methods, the method is installed on the metaclass.
+ (BOOL)injectSelector:(SEL)selector
             intoClass:(Class)cls
           classMethod:(BOOL)classMethod
        implementation:(KCObjCEvalMethodBlock)implementation
                 error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
