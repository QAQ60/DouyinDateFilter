#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

#import "rg_date_filter.h"

static NSString *const kDDFDaysKey = @"DDFDays";

static char kDDFPillKey;
static char kDDFBallKey;
static __weak id gDDFLastController;
static __weak UIViewController *gDDFLastProfile;

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
    // Newer builds rename the controller but keep it user scoped. Exclude the
    // liked/collected lists, which are also user scoped but must stay unfiltered.
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
    // calculateFilteredDataSource builds the list the grid actually renders;
    // keeping dataSource untouched makes the filter fully reversible.
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
    if (fabs(days) < 0.0001) return;
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

#pragma mark - Hooks

static IMP gDDFOriginalCalculate;

static void DDFCalculateHook(id self, SEL _cmd)
{
    if (gDDFOriginalCalculate) {
        ((void (*)(id, SEL))gDDFOriginalCalculate)(self, _cmd);
    }
    gDDFLastController = self;
    DDFApplyFilter(self);
}

static void DDFHookClass(Class cls, SEL selector, IMP replacement, IMP *original)
{
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
    NSLog(@"[DDF] hooked %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector));
}

#pragma mark - Settings

static NSString *DDFTitleForCurrentValue(void)
{
    double days = [[NSUserDefaults standardUserDefaults] doubleForKey:kDDFDaysKey];
    if (fabs(days) < 0.0001) return @"时间过滤";
    if (days > 0) return [NSString stringWithFormat:@"%g 天内", days];
    return [NSString stringWithFormat:@"%g 天以前", fabs(days)];
}

static UIWindow *DDFKeyWindow(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static UIViewController *DDFTopViewController(void)
{
    UIViewController *controller = DDFKeyWindow().rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static void DDFLogHierarchy(UIViewController *controller, NSInteger depth)
{
    if (!controller || depth > 4) return;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    NSLog(@"[DDF] %@%@", indent, NSStringFromClass([controller class]));
    for (UIViewController *child in controller.childViewControllers) {
        DDFLogHierarchy(child, depth + 1);
    }
}

@interface DDFConfigurator : NSObject
+ (instancetype)shared;
- (void)presentFrom:(UIViewController *)host;
- (void)pillTapped:(UIButton *)sender;
- (void)ballTapped:(UIButton *)sender;
- (void)ballPanned:(UIPanGestureRecognizer *)pan;
@end

@implementation DDFConfigurator

+ (instancetype)shared
{
    static DDFConfigurator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [DDFConfigurator new]; });
    return shared;
}

- (void)presentFrom:(UIViewController *)host
{
    if (!host) return;

    NSString *hint =
        @"比如输入 10 就只加载 10 天内发布的作品\n"
        @"支持小数点\n"
        @"比如 0.5 就是判断 12 小时内\n\n"
        @"支持输入负数 比如 -10 只刷 10 天以前发布的视频\n"
        @"（注意：输入过大可能无法加载出视频或功能无效）";

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
        UIViewController *top = DDFTopViewController();
        DDFLogHierarchy(top, 0);
        id controller = gDDFLastController;
        NSString *detail = [NSString stringWithFormat:@"当前页面：%@\n数据控制器：%@",
                            NSStringFromClass([top class]),
                            controller ? NSStringFromClass([controller class]) : @"未捕获"];
        UIAlertController *info = [UIAlertController alertControllerWithTitle:@"诊断（已写入日志）"
                                                                     message:detail
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [info addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:info animated:YES completion:nil];
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
        if (fabs(current) > 0.0001) field.text = [NSString stringWithFormat:@"%g", current];
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
            [weakSelf presentError:@"太大了，建议不超过 36500 天" host:weakHost];
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

    UIButton *pill = objc_getAssociatedObject(host, &kDDFPillKey);
    [pill setTitle:DDFTitleForCurrentValue() forState:UIControlStateNormal];

    // Rebuild from the untouched dataSource, then re-apply the new range.
    id controller = gDDFLastController;
    if ([controller respondsToSelector:@selector(calculateFilteredDataSource)]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(calculateFilteredDataSource));
    }
    @try {
        UICollectionView *collectionView = [host valueForKey:@"collectionView"];
        [collectionView reloadData];
    } @catch (__unused NSException *exception) {
    }
}

- (void)ballTapped:(UIButton *)sender
{
    [self presentFrom:DDFTopViewController()];
}

- (void)ballPanned:(UIPanGestureRecognizer *)pan
{
    UIView *ball = pan.view;
    UIWindow *window = ball.window;
    if (!ball || !window) return;

    CGPoint translation = [pan translationInView:window];
    CGPoint center = CGPointMake(ball.center.x + translation.x, ball.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:window];

    CGFloat half = ball.bounds.size.width / 2;
    center.x = MAX(half + 4, MIN(window.bounds.size.width - half - 4, center.x));
    center.y = MAX(half + 60, MIN(window.bounds.size.height - half - 40, center.y));
    ball.center = center;

    if (pan.state == UIGestureRecognizerStateEnded) {
        CGFloat targetX = (center.x < window.bounds.size.width / 2)
            ? half + 8
            : window.bounds.size.width - half - 8;
        [UIView animateWithDuration:0.2 animations:^{
            ball.center = CGPointMake(targetX, center.y);
        }];
    }
}

- (void)pillTapped:(UIButton *)sender
{
    UIViewController *host = gDDFLastProfile;
    if (!host) {
        UIResponder *responder = sender;
        while (responder && ![responder isKindOfClass:[UIViewController class]]) {
            responder = [responder nextResponder];
        }
        host = (UIViewController *)responder;
    }
    [self presentFrom:host];
}

@end

static void DDFInstallBall(void)
{
    UIWindow *window = DDFKeyWindow();
    if (!window) return;
    if (objc_getAssociatedObject(window, &kDDFBallKey)) return;

    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = CGRectMake(window.bounds.size.width - 56, window.bounds.size.height * 0.52, 44, 44);
    ball.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    ball.layer.cornerRadius = 22;
    ball.layer.borderWidth = 1;
    ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    ball.clipsToBounds = YES;
    ball.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [ball setTitle:@"过滤" forState:UIControlStateNormal];
    [ball setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [ball addTarget:[DDFConfigurator shared]
             action:@selector(ballTapped:)
   forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[DDFConfigurator shared]
                                                                        action:@selector(ballPanned:)];
    [ball addGestureRecognizer:pan];

    [window addSubview:ball];
    objc_setAssociatedObject(window, &kDDFBallKey, ball, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[DDF] floating ball installed on %@", NSStringFromClass([window class]));
}

#pragma mark - Entry pill

static void DDFAttachPill(UIViewController *controller)
{
    if (!controller || !controller.view) return;
    if (objc_getAssociatedObject(controller, &kDDFPillKey)) return;

    UIButton *pill = [UIButton buttonWithType:UIButtonTypeSystem];
    pill.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:0.88];
    [pill setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    pill.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    pill.layer.cornerRadius = 15;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    pill.clipsToBounds = YES;
    [pill setTitle:DDFTitleForCurrentValue() forState:UIControlStateNormal];
    [pill addTarget:[DDFConfigurator shared]
             action:@selector(pillTapped:)
   forControlEvents:UIControlEventTouchUpInside];

    CGFloat top = controller.view.safeAreaInsets.top + 54;
    CGFloat width = 86;
    pill.frame = CGRectMake(controller.view.bounds.size.width - width - 12, top, width, 30);
    pill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

    [controller.view addSubview:pill];
    objc_setAssociatedObject(controller, &kDDFPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static IMP gDDFOriginalViewDidAppear;

static void DDFViewDidAppearHook(id self, SEL _cmd, BOOL animated)
{
    if (gDDFOriginalViewDidAppear) {
        ((void (*)(id, SEL, BOOL))gDDFOriginalViewDidAppear)(self, _cmd, animated);
    }
    gDDFLastProfile = self;
    DDFAttachPill(self);
}

static void DDFScheduleBall(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DDFInstallBall();
    });
}

__attribute__((constructor))
static void DDFInitialize(void)
{
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        DDFScheduleBall();
    }];
    DDFScheduleBall();

    Class listController = objc_getClass("AWEListDataController");
    if (listController) {
        DDFHookClass(listController, @selector(calculateFilteredDataSource), (IMP)DDFCalculateHook, &gDDFOriginalCalculate);
    }

    NSArray<NSString *> *profileClasses = @[ @"AWEPostWorkViewController", @"AWEUserWorkViewController" ];
    for (NSString *name in profileClasses) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;

        // Only touch classes that implement viewDidAppear: themselves; hooking an
        // inherited implementation would put the pill on every controller in the app.
        SEL selector = @selector(viewDidAppear:);
        BOOL ownsMethod = NO;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            if (sel_isEqual(method_getName(methods[i]), selector)) { ownsMethod = YES; break; }
        }
        free(methods);
        if (!ownsMethod) continue;

        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        gDDFOriginalViewDidAppear = method_getImplementation(method);
        method_setImplementation(method, (IMP)DDFViewDidAppearHook);
        NSLog(@"[DDF] hooked %@ viewDidAppear:", name);
        break;
    }
}
