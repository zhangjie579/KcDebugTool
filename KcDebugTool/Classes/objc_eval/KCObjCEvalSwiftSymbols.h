#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A non-ObjC Swift type resolved from its metadata accessor symbol.
@interface KCObjCEvalSwiftType : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) uintptr_t metadata;
@end

/// Returns nil if the type is not present in the loaded Mach-O images.
FOUNDATION_EXPORT KCObjCEvalSwiftType * _Nullable KCObjCEvalFindSwiftType(NSString *name);

/// Returns YES only if a matching Swift symbol was invoked. May throw a
/// KCObjCEvalError exception for ambiguity or unsupported Swift ABI types.
FOUNDATION_EXPORT BOOL KCObjCEvalInvokeSwift(id receiver, NSString *member,
                                             NSArray *arguments, BOOL property,
                                             id _Nullable * _Nullable output,
                                             BOOL * _Nullable isVoid);

NS_ASSUME_NONNULL_END
