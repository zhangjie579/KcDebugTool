//
//  NSString+KcExtension.h
//  OCTest
//
//  Created by samzjzhang on 2020/6/10.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSString (KcExtension)

- (CGSize)kc_sizeWithMaxSize:(CGSize)maxSize fontSize:(CGFloat)fontSize;
- (CGSize)kc_sizeWithMaxSize:(CGSize)maxSize font:(UIFont *)font;

/// 格式化显示的JSON
+ (nullable NSString *)kc_JSONFormatterWithDict:(NSDictionary<NSString *, id> *)dict;
- (nullable NSDictionary<NSString *, id> *)kc_JSON;

/// query string -> NSDictionary
- (nullable NSDictionary<NSString *, NSString *> *)kc_JSONFromQuery;

/// 获取JSON, key=value&key1=value1 => [key : value, key1 : value1]
/// @param separator 连接2个key直接的分隔符, 上面例子为&
/// @param keyValueSeparator key、value之间的分隔符, 上面例子为=
- (NSDictionary<NSString *, id> *)kc_JSONWithSeparatedByString:(NSString *)separator keyValueSeparator:(NSString *)keyValueSeparator;

#pragma mark - URL编码、解码

- (NSString *)URLEncoded;
- (NSString *)URLDecoded;

/**
 对字符串的每个字符进行UTF-8编码
 
 @return 百分号编码后的字符串
 */
- (NSString *)URLUTF8EncodingString;

/**
 对字符串的每个字符进行彻底的 UTF-8 解码
 连续编码2次，需要连续解码2次，第三次继续解码时，则返回为空
 @return 百分号编码解码后的字符串
 */
- (NSString *)URLUTF8DecodingString;

@end

NS_ASSUME_NONNULL_END
