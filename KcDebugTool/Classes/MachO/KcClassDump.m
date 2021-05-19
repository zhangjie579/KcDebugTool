//
//  KcClassDump.m
//  objc-001
//
//  Created by 张杰 on 2021/5/13.
//

#import "KcClassDump.h"
#import <objc/message.h>

struct kc_xtrace_arg {
    const char *name, *type;
    int stackOffset;
    NSString *typeStr; // 不加这个, getArgumentTypeAtIndex 会野指针
};

@implementation KcClassDump

+ (void)dumpClass:(Class)aClass {
    NSMutableString *str = [NSMutableString string];
    [str appendFormat:@"@interface %s : %s {\n", class_getName(aClass), class_getName(class_getSuperclass(aClass))];

    unsigned c;
    Ivar *ivars = class_copyIvarList(aClass, &c);
    for ( unsigned i=0 ; i<c ; i++ ) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        [str appendFormat:@"    %@ %s; // %s\n", [self xtype:type], ivar_getName(ivars[i]), type];
    }
    free( ivars );
    [str appendString:@"}\n\n"];

    objc_property_t *props = class_copyPropertyList(aClass, &c);
    for ( unsigned i=0 ; i<c ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        [str appendFormat:@"@property () %@ %s; // %s\n", [self xtype:attrs+1], property_getName(props[i]), attrs];
    }
    free( props );

    [self dumpMethodType:"+" forClass:object_getClass(aClass) into:str];
    [self dumpMethodType:"-" forClass:aClass into:str];
    printf( "%s\n@end\n\n", [str UTF8String] );
}

+ (void)dumpMethodType:(const char *)mtype forClass:(Class)aClass into:(NSMutableString *)str {
    [str appendString:@"\n"];
    unsigned mc;
    Method *methods = class_copyMethodList(aClass, &mc);
    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(method_getName(methods[i]));
        const char *type = method_getTypeEncoding(methods[i]);
        [str appendFormat:@"%s (%@)", mtype, [self xtype:type]];

#define MAXARGS 99
        struct kc_xtrace_arg args[MAXARGS+1];
        [self extractSelector:name into:args maxargs:MAXARGS];
        [self extractOffsets:type into:args maxargs:MAXARGS];

        for ( int a=0 ; a<MAXARGS ; a++ ) {
            if ( !args[a].name[0] )
                break;
            [str appendFormat:@"%.*s", (int)(args[a+1].name-args[a].name), args[a].name];
            if ( !args[a].type )
                break;
            [str appendFormat:@"(%@)a%d ", [self xtype:args[a].type], a];
        }

        [str appendFormat:@"; // %s\n", type];
    }

    free( methods );
}

+ (int)extractSelector:(const char *)name into:(struct kc_xtrace_arg *)args maxargs:(int)maxargs {

    for ( int i=0 ; i<maxargs ; i++ ) {
        args->name = name;
        const char *next = index( name, ':' );
        if ( next ) {
            name = next+1;
            args++;
        }
        else {
            args[1].name = name+strlen(name);
            return i;
        }
    }

    return -1;
}

+ (int)extractOffsets:(const char *)type into:(struct kc_xtrace_arg *)args maxargs:(int)maxargs {
    @try {
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:type];
        int acount = (int)[sig numberOfArguments];

        for ( int i=2 ; i<acount ; i++ ) {
            args[i-2].type = [sig getArgumentTypeAtIndex:i];
        }
            

        return acount-2;
    }
    @catch ( NSException *e ) {
        NSLog( @"Xtrace: exception %@ on signature: %s", e, type );
        [self originalExtractOffsets:type into:args maxargs:maxargs];
    }
}

+ (int)originalExtractOffsets:(const char *)type into:(struct kc_xtrace_arg *)args maxargs:(int)maxargs {
    int frameLen = -1;

    for ( int i=0 ; i<maxargs ; i++ ) {
        args->type = type;
        while ( !isdigit(*type) || type[1] == ',' )
            type++;
        args->stackOffset = -atoi(type);
        if ( i==0 )
            frameLen = args->stackOffset;
        while ( isdigit(*type) )
            type++;
        if ( i>2 )
            args++;
        else
            args->type = NULL;
        if ( !*type ) {
            args->stackOffset = frameLen;
            return i;
        }
    }

    return -1;
}

+ (NSString *)xtype:(const char *)type {
    switch ( type[0] ) {
        case 'V': return @"oneway void";
        case 'v': return @"void";
        case 'B': return @"bool";
        case 'c': return @"char";
        case 'C': return @"unsigned char";
        case 's': return @"short";
        case 'S': return @"unsigned short";
        case 'i': return @"int";
        case 'I': return @"unsigned";
        case 'f': return @"float";
        case 'd': return @"double";
#ifndef __LP64__
        case 'q': return @"long long";
#else
        case 'q':
#endif
        case 'l': return @"long";
#ifndef __LP64__
        case 'Q': return @"unsigned long long";
#else
        case 'Q':
#endif
        case 'L': return @"unsigned long";
        case ':': return @"SEL";
        case '#': return @"Class";
        case '@': return [self xtype:type+1 star:" *"];
        case '^': return [self xtype:type+1 star:" *"];
        case '{': return [self xtype:type star:""];
        case 'r':
            return [@"const " stringByAppendingString:[self xtype:type+1]];
        case '*': return @"char *";
        default:
            return @"id";
    }
}

+ (NSString *)xtype:(const char *)type star:(const char *)star {
    if ( type[-1] == '@' ) {
        if ( type[0] != '"' )
            return @"id";
        else if ( type[1] == '<' )
            type++;
    }
    if ( type[-1] == '^' && type[0] != '{' )
        return [[self xtype:type] stringByAppendingString:@" *"];

    const char *end = ++type;
    while ( isalpha(*end) || *end == '_' || *end == ',' )
        end++;
    if ( type[-1] == '<' )
        return [NSString stringWithFormat:@"id<%.*s>", (int)(end-type), type];
    else
        return [NSString stringWithFormat:@"%.*s%s", (int)(end-type), type, star];
}

@end
