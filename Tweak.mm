#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

#import "rg_date_filter.h"

static NSString *const kDDFDaysKey = @"DDFDays";
static NSString *const kDDFHostKey = @"ddf.host";

static char kDDFSettingsEntryKey;
static __weak id gDDFLastController;

#pragma mark - Douyin model plumbing

// AWEAwemeModel exposes createTime (seconds). Some builds wrap it as
// NSString or hand back milliseconds, so normalise defensively.
static NSDate *DDFDateForAweme(id object)
{
    static NSArray<NSString *> *paths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = @[ @"createTime", @"create_time", @"aweme.createTime", @"model.createTime" ];
    });

    for (NSString *path in paths) {
        @try {
            id value = [object valueForKeyPath:path];
            double stamp = 0;
            if ([value isKindOfClass:[NSNumber class]]) stamp = [value doubleValue];
            else if ([value isKindOfClass:[NSString class]]) stamp = [value doubleValue];
            if (stamp > 1000000000.0) {
                if (stamp > 100000000000.0) stamp /= 1000.0;
                return [NSDate dateWithTimeIntervalSince1970:stamp];
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static BOOL DDFIsProfilePostsController(id controller)
{
    NSString *name = NSStringFromClass([controller class]);
    if ([name containsString:@"UserPosts"] ||
        [name containsString:@"PostWork"] ||
        [name containsString:@"UserWork"]) {
        return YES;
    }
    if ([name containsString:@"User"] &&
        ![name containsString:@"Like"] &&
        ![name containsString:@"Collect"] &&
        ![name containsString:@"Favorite"]) {
        return YES;
    }
    return NO;
}

static NSMutableArray *DDFVisibleList(id controller)
{
    // Keeping dataSource untouched makes the filter fully reversible.
    @try {
        id filtered = [controller valueForKey:@"filteredDataSource"];
        if ([filtered isKindOfClass:[NSMutableArray class]]) return filtered;
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static void DDFApplyFilter(id controller)
{
    double days = [[NSUserDefaults standardUserDefaults] doubleForKey:kDDFDaysKey];
    if (fabs(days) < RG_FILTER_MIN_DAYS) return;
    if (!DDFIsProfilePostsController(controller)) return;

    NSMutableArray *list = DDFVisibleList(controller);
    if (!list || list.count == 0) return;

    RGDateFilter filter = rg_filter_make(days);
    NSDate *now = [NSDate date];
    NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];

    [list enumerateObjectsUsingBlock:^(id object, NSUInteger index, BOOL *stop) {
        NSDate *takenAt = DDFDateForAweme(object);
        if (!takenAt) return;   // never drop undated items
        if (!rg_filter_should_keep(filter, [now timeIntervalSinceDate:takenAt])) {
            [drop addIndex:index];
        }
    }];

    if (drop.count > 0) {
        NSLog(@"[DDF] %@: %lu -> %lu (days=%g)",
              NSStringFromClass([controller class]),
              (unsigned long)list.count,
              (unsigned long)(list.count - drop.count),
              days);
        [list removeObjectsAtIndexes:drop];
    }
}

static IMP gDDFOriginalCalculate;

static void DDFCalculateHook(id self, SEL _cmd)
{
    if (gDDFOriginalCalculate) {
        ((void (*)(id, SEL))gDDFOriginalCalculate)(self, _cmd);
    }
    gDDFLastController = self;
    DDFApplyFilter(self);
}

#pragma mark - Diagnostics

static NSArray<NSString *> *DDFCandidateClassNames(void)
{
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) return @[];
    count = objc_getClassList(classes, count);

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (![name hasPrefix:@"AWE"]) continue;
        if ([name containsString:@"DataController"] || [name containsString:@"DataManager"]) {
            [names addObject:name];
        }
    }
    free(classes);
    [names sortUsingSelector:@selector(compare:)];
    return names;
}

static NSString *DDFDiagnosticsText(void)
{
    Class listClass = objc_getClass("AWEListDataController");
    NSArray<NSString *> *candidates = DDFCandidateClassNames();
    NSArray *sample = candidates.count > 6 ? [candidates subarrayWithRange:NSMakeRange(0, 6)] : candidates;

    NSString *controllerName = gDDFLastController
        ? NSStringFromClass([gDDFLastController class])
        : @"未捕获";

    return [NSString stringWithFormat:
            @"AWEListDataController：%@\n"
            @"数据控制器：%@\n"
            @"候选类（%lu）：\n%@",
            listClass ? @"存在" : @"不存在",
            controllerName,
            (unsigned long)candidates.count,
            sample.count ? [sample componentsJoinedByString:@"\n"] : @"无"];
}

#pragma mark - Settings entry

static UIViewController *DDFTopViewController(void)
{
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
    }
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;

    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

@interface DDFConfigurator : NSObject
+ (instancetype)shared;
- (void)presentFrom:(UIViewController *)host;
- (void)settingsTapped:(UIBarButtonItem *)sender;
@end

static void DDFAddSettingsEntry(UIViewController *controller)
{
    if (!controller) return;
    NSString *name = NSStringFromClass([controller class]);
    if ([name rangeOfString:@"Setting" options:NSCaseInsensitiveSearch].location == NSNotFound) return;

    UINavigationItem *navigationItem = controller.navigationItem;
    if (!navigationItem) return;
    if (objc_getAssociatedObject(controller, &kDDFSettingsEntryKey)) return;

    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"时间过滤"
                                                             style:UIBarButtonItemStylePlain
                                                            target:[DDFConfigurator shared]
                                                            action:@selector(settingsTapped:)];
    objc_setAssociatedObject(item, kDDFHostKey.UTF8String, controller, OBJC_ASSOCIATION_ASSIGN);

    NSMutableArray *items = [navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items insertObject:item atIndex:0];
    navigationItem.rightBarButtonItems = items;

    objc_setAssociatedObject(controller, &kDDFSettingsEntryKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[DDF] settings entry added to %@", name);
}

static IMP gDDFOriginalUIViewControllerAppear;

static void DDFAppearHook(id self, SEL _cmd, BOOL animated)
{
    if (gDDFOriginalUIViewControllerAppear) {
        ((void (*)(id, SEL, BOOL))gDDFOriginalUIViewControllerAppear)(self, _cmd, animated);
    }
    DDFAddSettingsEntry(self);
}

@implementation DDFConfigurator

+ (instancetype)shared
{
    static DDFConfigurator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [DDFConfigurator new]; });
    return shared;
}

- (void)settingsTapped:(UIBarButtonItem *)sender
{
    UIViewController *host = objc_getAssociatedObject(sender, kDDFHostKey.UTF8String);
    [self presentFrom:host ?: DDFTopViewController()];
}

- (void)presentFrom:(UIViewController *)host
{
    if (!host) return;

    NSString *hint =
        @"比如输入 10 就只加载 10 天内发布的作品\n"
        @"支持小数点\n"
        @"比如 0.5 就是判断 12 小时内\n\n"
        @"支持输入负数 比如 -10 只刷 10 天以前发布的视频\n"
        @"（注意：输入过大可能无法加载出视频或功能无效）\n"
        @"最长 1 年，最短 1 分钟。";

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"提示"
                                            message:hint
                                     preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"前往输入"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf presentInputFrom:host];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"诊断"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSLog(@"[DDF] %@", DDFDiagnosticsText());
        UIAlertController *info = [UIAlertController alertControllerWithTitle:@"诊断（已写入日志）"
                                                                     message:DDFDiagnosticsText()
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [info addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [DDFTopViewController() presentViewController:info animated:YES completion:nil];
    }]];

    [host presentViewController:alert animated:YES completion:nil];
}

- (void)presentInputFrom:(UIViewController *)host
{
    double current = [[NSUserDefaults standardUserDefaults] doubleForKey:kDDFDaysKey];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"输入天数"
                                            message:@"正数 = 最近 N 天，负数 = N 天以前，0 = 关闭"
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.placeholder = @"10 / 0.5 / -10";
        field.textAlignment = NSTextAlignmentCenter;
        if (fabs(current) >= RG_FILTER_MIN_DAYS) field.text = [NSString stringWithFormat:@"%g", current];
    }];

    __weak typeof(self) weakSelf = self;
    __weak UIViewController *weakHost = host;

    [alert addAction:[UIAlertAction actionWithTitle:@"清除"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf applyDays:0 host:weakHost];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        double value = 0;
        RGDateFilter filter;
        RGParseResult result = rg_parse_days(text.UTF8String, &value, &filter);

        if (result == RGParseInvalid) {
            [weakSelf presentError:@"只能输入数字、小数点和负号" host:weakHost];
            return;
        }
        if (result == RGParseTooLarge) {
            [weakSelf presentError:@"最长 1 年（365 天）" host:weakHost];
            return;
        }
        if (result == RGParseTooSmall) {
            [weakSelf presentError:@"最短 1 分钟（0.0007 天）" host:weakHost];
            return;
        }
        [weakSelf applyDays:(result == RGParseEmpty || result == RGParseZero) ? 0 : value
                       host:weakHost];
    }]];

    [host presentViewController:alert animated:YES completion:nil];
}

- (void)presentError:(NSString *)message host:(UIViewController *)host
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入无效"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}

- (void)applyDays:(double)days host:(UIViewController *)host
{
    [[NSUserDefaults standardUserDefaults] setDouble:days forKey:kDDFDaysKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    id controller = gDDFLastController;
    if ([controller respondsToSelector:@selector(calculateFilteredDataSource)]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(calculateFilteredDataSource));
    }
}

@end

#pragma mark - Bootstrap

static void DDFHookClass(Class cls, SEL selector, IMP replacement, IMP *original)
{
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
    NSLog(@"[DDF] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

// Settings controllers that override viewDidAppear: without calling super would
// miss a UIViewController-level swizzle, so give each its own block hook.
static void DDFHookSettingsClasses(void)
{
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) return;
    count = objc_getClassList(classes, count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if ([name rangeOfString:@"Setting" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;

        SEL selector = @selector(viewDidAppear:);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL owns = NO;
        for (unsigned int j = 0; j < methodCount; j++) {
            if (sel_isEqual(method_getName(methods[j]), selector)) { owns = YES; break; }
        }
        free(methods);
        if (!owns) continue;

        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;

        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(id receiver, BOOL animated) {
            ((void (*)(id, SEL, BOOL))original)(receiver, selector, animated);
            DDFAddSettingsEntry(receiver);
        });
        method_setImplementation(method, replacement);
        NSLog(@"[DDF] settings class hooked: %@", name);
    }
    free(classes);
}

__attribute__((constructor))
static void DDFInitialize(void)
{
    Class listController = objc_getClass("AWEListDataController");
    if (listController) {
        DDFHookClass(listController, @selector(calculateFilteredDataSource), (IMP)DDFCalculateHook, &gDDFOriginalCalculate);
    } else {
        NSLog(@"[DDF] AWEListDataController not found in this build");
    }

    Method appear = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (appear) {
        gDDFOriginalUIViewControllerAppear = method_getImplementation(appear);
        method_setImplementation(appear, (IMP)DDFAppearHook);
    }

    DDFHookSettingsClasses();

    NSLog(@"[DDF] ready (listController=%@, candidates=%lu)",
          listController ? @"yes" : @"no",
          (unsigned long)DDFCandidateClassNames().count);
}
