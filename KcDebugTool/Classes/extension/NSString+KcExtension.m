//
//  NSString+KcExtension.m
//  OCTest
//
//  Created by samzjzhang on 2020/6/10.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "NSString+KcExtension.h"
#import "UIColor+KcDebugTool.h"

@implementation NSString (KcExtension)

- (CGSize)kc_sizeWithMaxSize:(CGSize)maxSize fontSize:(CGFloat)fontSize {
    return [self kc_sizeWithMaxSize:maxSize font:[UIFont systemFontOfSize:fontSize]];
}

- (CGSize)kc_sizeWithMaxSize:(CGSize)maxSize font:(UIFont *)font {
    CGSize size = [self boundingRectWithSize:maxSize options:NSStringDrawingUsesLineFragmentOrigin attributes:@{
        NSFontAttributeName: font
    } context:nil].size;
    size.width = ceil(size.width);
    return size;
}

/// 格式化显示的JSON
+ (nullable NSString *)kc_JSONFormatterWithDict:(NSDictionary<NSString *, id> *)dict {
    if (!dict) {
        return nil;
    }
    
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return nil;
}

- (nullable NSDictionary<NSString *, id> *)kc_JSON {
    NSData *jsonData = [self dataUsingEncoding:NSUTF8StringEncoding];
    return [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
}

/// query string -> NSDictionary
- (nullable NSDictionary<NSString *, NSString *> *)kc_JSONFromQuery {
    return [self kc_JSONWithSeparatedByString:@"&" keyValueSeparator:@"="];
}

/// 获取JSON, key=value&key1=value1 => [key : value, key1 : value1]
/// @param separator 连接2个key直接的分隔符, 上面例子为&
/// @param keyValueSeparator key、value之间的分隔符, 上面例子为=
- (NSDictionary<NSString *, id> *)kc_JSONWithSeparatedByString:(NSString *)separator keyValueSeparator:(NSString *)keyValueSeparator {
    // [key=value]
    NSArray<NSString *> *keyValues = [self componentsSeparatedByString:separator];
    NSMutableDictionary<NSString *, NSString *> *dict = [[NSMutableDictionary alloc] init];
    for (NSString *keyValue in keyValues) {
        if (![keyValue containsString:keyValueSeparator]) {
            continue;
        }
        NSArray<NSString *> *items = [keyValue componentsSeparatedByString:keyValueSeparator];
        if (items.count == 2) {
            dict[items[0]] = items[1];
        } else if (items.count == 1) {
            NSString *lastStr = [keyValue substringFromIndex:keyValue.length - 1];
            if ([lastStr isEqualToString:keyValueSeparator]) {
                dict[items[0]] = @"";
            }
        }
    }
    return [dict copy];
}


#pragma mark - URL编码、解码

- (NSString *)URLEncoded {
    return [self stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
}

- (NSString *)URLDecoded {
    return [self stringByRemovingPercentEncoding];
}

/**
 对字符串的每个字符进行UTF-8编码
 
 @return 百分号编码后的字符串
 */
- (NSString *)URLUTF8EncodingString {
    if (self.length == 0) {
        return self;
    }
    NSCharacterSet *characterSet = [NSCharacterSet characterSetWithCharactersInString:@""];
    NSString *encodeStr = [self stringByAddingPercentEncodingWithAllowedCharacters:characterSet];
    return encodeStr;
}

/**
 对字符串的每个字符进行彻底的 UTF-8 解码
 连续编码2次，需要连续解码2次，第三次继续解码时，则返回为空
 @return 百分号编码解码后的字符串
 */
- (NSString *)URLUTF8DecodingString {
    if (self.length == 0) {
        return self;
    }
    if ([self stringByRemovingPercentEncoding] == nil
        || [self isEqualToString:[self stringByRemovingPercentEncoding]]) {
        return self;
    }
    NSString *decodedStr = [self stringByRemovingPercentEncoding];
    while ([decodedStr stringByRemovingPercentEncoding] != nil) {
        decodedStr = [decodedStr stringByRemovingPercentEncoding];
    }
    return decodedStr;
}

@end

@implementation NSAttributedString (KcDebugTool)

- (NSString *)kc_debug_textColor {
//    NSFontAttributeName;
//    NSForegroundColorAttributeName;
//    [self enumerateAttributesInRange:NSMakeRange(0, self.length) options:0 usingBlock:^(NSDictionary<NSAttributedStringKey,id> * _Nonnull attrs, NSRange range, BOOL * _Nonnull stop) {
//        UIColor *_Nullable color = attrs[NSForegroundColorAttributeName];
//        //        UIFont *_Nullable font = attrs[NSFontAttributeName];
//        
//        if (!color) {
//            return;
//        }
//        
//    }];
    
    NSMutableString *resultString = [NSMutableString string];
    
    [self enumerateAttribute:NSForegroundColorAttributeName inRange:NSMakeRange(0, self.length) options:0 usingBlock:^(id  _Nullable value, NSRange range, BOOL * _Nonnull stop) {
        if (![value isKindOfClass:[UIColor class]]) {
            return;
        }
        NSString *subString = [self.string substringWithRange:range];
        NSString *hexString = [value kc_hexString];
        
        [resultString appendFormat:@"[%@: %@] - ", subString, hexString];
    }];
    
    if (resultString.length <= 0) {
        return resultString;
    }
    
    [resultString deleteCharactersInRange:NSMakeRange(resultString.length - 3, 3)];
    
    return resultString;
}

- (NSString *)kc_debug_font {
    NSMutableString *resultString = [NSMutableString string];
    
    [self enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, self.length) options:0 usingBlock:^(id  _Nullable value, NSRange range, BOOL * _Nonnull stop) {
        if (![value isKindOfClass:[UIFont class]]) {
            return;
        }
        
        UIFont *font = (UIFont *)value;
        
//        // 获取字体名称
//        let fontName = font.fontName
//
//        // 获取字体大小
//        let fontSize = font.pointSize
        
        NSString *subString = [self.string substringWithRange:range];
        NSString *fontDesc = [NSString stringWithFormat:@"%@:%.2f", font.fontName, font.pointSize];
        
        [resultString appendFormat:@"[%@: %@] - ", subString, fontDesc];
    }];
    
    if (resultString.length <= 0) {
        return resultString;
    }
    
    [resultString deleteCharactersInRange:NSMakeRange(resultString.length - 3, 3)];
    
    return resultString;
}

@end
