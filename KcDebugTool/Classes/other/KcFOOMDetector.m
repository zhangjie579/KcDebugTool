//
//  KcFOOMDetector.m
//  Pods
//
//  Created by 张杰 on 2023/4/25.
//

#import "KcFOOMDetector.h"
#import <sys/stat.h>
#if __has_include("fishhook/fishhook.h")
#import "fishhook/fishhook.h"
#else
#import "fishhook.h"
#endif

NSString *KcPreviousBundleVersionKey = @"KcPreviousBundleVersionKey";
NSString *KcAppWasTerminatedKey = @"KcAppWasTerminatedKey";
/// 是否在后台
NSString *KcAppWasInBackgroundKey = @"KcAppWasInBackgroundKey";
NSString *KcAppDidCrashKey = @"KcAppDidCrashKey";
NSString *KcPreviousOSVersionKey = @"KcPreviousOSVersionKey";
NSString *KcAppDidQuitKey = @"KcAppDidQuitKey";
NSString *KcAppWatchDogKey = @"KcAppWatchDogKey";
static char *intentionalQuitPathname;

@interface KcFOOMDetector ()

@property (nonatomic) dispatch_semaphore_t semaphore;
@property (nonatomic) dispatch_queue_t queue;
@property (atomic) BOOL monitoring;

@end

@implementation KcFOOMDetector

+ (void)beginMonitoringMemoryEventsWithHandler:(void(^)(BOOL wasInForeground, BOOL watchDog))handler
                                 crashDetector:(BOOL(^)(void))crashDetector
                               appVersionBlock:(NSString *(^_Nullable)(void))appVersionBlock {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL watchDog = [defaults boolForKey:KcAppWatchDogKey];
    
    [[self sharedInstance] beginApplicationMonitoring];
//    signal(SIGABRT, KcIntentionalQuitHandler);
//    signal(SIGQUIT, KcIntentionalQuitHandler);

    // Set up the static path for intentional aborts 为有意中止设置静态路径, 为什么不hook exit、abort❓
//    if ([KcPathUtilities intentionalQuitPathname]) {
//        intentionalQuitPathname = strdup([KcPathUtilities intentionalQuitPathname]);
//    }

    // 没有设置crash block
    BOOL(^detector)(void) = crashDetector;
    if (!detector) {
        [self setupDefaultCrashReporting];
        detector = [self defaultCrashDetector];
    }

    // 有意退出的
    BOOL didIntentionallyQuit = [defaults boolForKey:KcAppDidQuitKey];
//    BOOL didIntentionallyQuit = NO;
//    struct stat statbuffer;
//    if (stat(intentionalQuitPathname, &statbuffer) == 0){
//        // A file exists at the path, we had an intentional quit
//        didIntentionallyQuit = YES;
//    }
    // 是否crash
    BOOL didCrash = detector();
    BOOL didTerminate = [defaults boolForKey:KcAppWasTerminatedKey];
    // 升级app
    NSString *appVersion = appVersionBlock != nil ? appVersionBlock() : self.currentBundleVersion;
    BOOL didUpgradeApp = ![appVersion isEqualToString:[self previousBundleVersion]];
    // 升级系统
    BOOL didUpgradeOS = ![[self currentOSVersion] isEqualToString:[self previousOSVersion]];
    
    if (!(didIntentionallyQuit || didCrash || didTerminate || didUpgradeApp || didUpgradeOS)) {
        if (handler) {
            // 是否在后台
            BOOL wasInBackground = [[NSUserDefaults standardUserDefaults] boolForKey:KcAppWasInBackgroundKey];
            handler(!wasInBackground, watchDog);
        }
    }

    [defaults setObject:appVersion forKey:KcPreviousBundleVersionKey];
    [defaults setObject:[self currentOSVersion] forKey:KcPreviousOSVersionKey];
    [defaults setBool:NO forKey:KcAppWasTerminatedKey];
    [defaults setBool:NO forKey:KcAppWasInBackgroundKey];
    [defaults setBool:NO forKey:KcAppDidCrashKey];
    [defaults setBool:NO forKey:KcAppDidQuitKey];
    [defaults synchronize];
    // Remove intentional quit file
//    unlink(intentionalQuitPathname);
}

#pragma mark termination and backgrounding

+ (instancetype)sharedInstance {
    static id sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        self.queue = dispatch_queue_create("kc.com.monitor.watchdog", DISPATCH_QUEUE_SERIAL);
        self.semaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)beginApplicationMonitoring {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    
    rebind_symbols((struct rebinding[3]) {
        {"_exit", (void *)_my_exit, (void **)&_orig_exit},
        {"exit", (void *)my_exit, (void **)&orig_exit},
        {"abort", (void *)my_abort, (void **)&orig_abort}
    }, 3);
    
    dispatch_async(self.queue, ^{
        while (self.monitoring) {
            // 能再来一次说明没问题
            [NSUserDefaults.standardUserDefaults setBool:false forKey:KcAppWatchDogKey];
            [NSUserDefaults.standardUserDefaults synchronize];
            
            __block BOOL timeout = true;
            dispatch_async(dispatch_get_main_queue(), ^{
                timeout = false;
                dispatch_semaphore_signal(self.semaphore);
            });
            [NSThread sleepForTimeInterval:5];
            
            if (timeout) {
                [NSUserDefaults.standardUserDefaults setBool:true forKey:KcAppWatchDogKey];
                [NSUserDefaults.standardUserDefaults synchronize];
            }
            
            dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
        }
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

/// 程序即将终止
/// 对该方法的实施大约有五秒钟的时间来执行任何任务并返回。如果该方法在时间到期之前没有返回，系统可能会完全终止该过程。
- (void)applicationWillTerminate:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:KcAppWasTerminatedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:KcAppWasInBackgroundKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:KcAppWasInBackgroundKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark app version

+ (NSString *)currentBundleVersion {
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *majorVersion = infoDictionary[@"CFBundleShortVersionString"];
    NSString *minorVersion = infoDictionary[@"CFBundleVersion"];
    return [NSString stringWithFormat:@"%@.%@", majorVersion, minorVersion];
}

+ (NSString *)previousBundleVersion {
    return [[NSUserDefaults standardUserDefaults] objectForKey:KcPreviousBundleVersionKey];
}

#pragma mark OS version

+ (NSString *)stringFromOperatingSystemVersion:(NSOperatingSystemVersion)version {
    return [NSString stringWithFormat:@"%@.%@.%@", @(version.majorVersion), @(version.minorVersion), @(version.patchVersion)];
}

+ (NSString *)currentOSVersion {
    return [self stringFromOperatingSystemVersion:[[NSProcessInfo processInfo] operatingSystemVersion]];
}

+ (NSString *)previousOSVersion {
    return [[NSUserDefaults standardUserDefaults] objectForKey:KcPreviousOSVersionKey];
}

#pragma mark crash reporting

+ (void)setupDefaultCrashReporting {
    if (NSGetUncaughtExceptionHandler()) {
        NSLog(@"Warning: something in your application (probably a crash reporting framework) has already set an uncaught exception handler. This will break that code. You should pass a crashReporter block to checkForOutOfMemoryEventsWithHandler:crashReporter: that uses your crash reporting framework.");
    }
    
    NSSetUncaughtExceptionHandler(&defaultExceptionHandler);
}

static void defaultExceptionHandler (NSException *exception) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:KcAppDidCrashKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static void KcIntentionalQuitHandler(int signal) {
    creat(intentionalQuitPathname, S_IREAD | S_IWRITE);
}

+ (BOOL(^)(void))defaultCrashDetector {
    return ^() {
        return [[NSUserDefaults standardUserDefaults] boolForKey:KcAppDidCrashKey];
    };
}

#pragma mark - exit

static void (*_orig_exit)(int);
static void (*orig_exit)(int);
static void (*orig_abort)(void);

/// 退出 - 通知更新状态
static void my_exit(int value) {
    exit_before();
    orig_exit(value);
}

static void _my_exit(int value) {
    exit_before();
    _orig_exit(value);
}

static void my_abort() {
    exit_before();
    orig_abort();
}

static void exit_before() {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:KcAppDidQuitKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end

