#import "TNRootViewController.h"
#import "TNSidebarViewController.h"
#import "TNSettingsViewController.h"
#import "TNHomeViewController.h"
#import "TNBrowseViewController.h"
#import "TNSearchViewController.h"
#import "TNLibraryViewController.h"
#import "TNTrackListViewController.h"
#import "TNNowPlayingViewController.h"
#import "TNPlayerBar.h"
#import "TNPlayer.h"
#import "TNSettings.h"
#import "TNModels.h"
#import "TNTheme.h"
#import "TNModern.h"
#import "TNCommon.h"

static __weak TNRootViewController *TNRootShared;

@interface TNRootViewController () <UITabBarDelegate>
@property (nonatomic, strong) NSMutableDictionary *navs;            // @(TNSection) -> UINavigationController
@property (nonatomic, strong) UINavigationController *current;
@property (nonatomic, readwrite) TNSection section;
@property (nonatomic, strong) TNSidebarViewController *sidebar;     // iPad
@property (nonatomic, strong) UIView *divider;
@property (nonatomic, strong) UITabBar *tabBar;                     // iPhone
@property (nonatomic, strong) NSArray *tabSections;
@property (nonatomic, strong) TNPlayerBar *playerBar;
@property (nonatomic, strong) UILabel *toast;
@property (nonatomic) NSUInteger toastGeneration;
@end

@implementation TNRootViewController

+ (instancetype)shared { return TNRootShared; }

- (instancetype)init
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        TNRootShared = self;
        _navs = [NSMutableDictionary dictionary];
        _section = (TNSection)-1;
    }
    return self;
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    TNTheme *theme = [TNTheme shared];
    self.view.backgroundColor = [theme plainBackgroundColor];
    BOOL pad = TNIsPad();
    if (pad) {
        self.sidebar = [[TNSidebarViewController alloc] init];
        __weak TNRootViewController *weakSelf = self;
        self.sidebar.onSection = ^(TNSection section) { [weakSelf showSection:section]; };
        self.sidebar.onPlaylist = ^(TNPlaylist *playlist) { [weakSelf showSidebarPlaylist:playlist]; };
        [self addChildViewController:self.sidebar];
        [self.view addSubview:self.sidebar.view];
        [self.sidebar didMoveToParentViewController:self];
        self.divider = [[UIView alloc] initWithFrame:CGRectZero];
        self.divider.backgroundColor = [UIColor colorWithWhite:0 alpha:0.9];
        [self.view addSubview:self.divider];
    } else {
        self.tabSections = @[ @(TNSectionHome), @(TNSectionExplore), @(TNSectionSearch), @(TNSectionLibrary), @(TNSectionSettings) ];
        NSArray *titles = @[ L(@"Home"), L(@"Explore"), L(@"Search"), L(@"Library"), L(@"Settings") ];
        NSArray *icons = @[ @(TNIconHome), @(TNIconExplore), @(TNIconSearch), @(TNIconLibrary), @(TNIconSettings) ];
        NSMutableArray *items = [NSMutableArray array];
        for (NSUInteger i = 0; i < titles.count; i++) {
            UITabBarItem *item = [[UITabBarItem alloc] initWithTitle:titles[i] image:[theme icon:(TNIcon)[icons[i] integerValue] size:28] tag:(NSInteger)i];
            [items addObject:item];
        }
        self.tabBar = [[UITabBar alloc] initWithFrame:CGRectZero];
        self.tabBar.items = items;
        self.tabBar.delegate = self;
        [self.view addSubview:self.tabBar];
    }
    self.playerBar = [[TNPlayerBar alloc] initWithFrame:CGRectZero compact:!pad];
    [self.view addSubview:self.playerBar];
    [self showSection:TNSectionHome];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(playerChanged) name:TNPlayerDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(showQueue) name:@"TNShowQueue" object:nil];
    [nc addObserver:self selector:@selector(showLyrics) name:@"TNShowLyrics" object:nil];
    [nc addObserver:self selector:@selector(playerFailed:) name:TNPlayerDidFailNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self becomeFirstResponder];   // the lock screen's and the headphones' controls
}

- (BOOL)canBecomeFirstResponder { return YES; }
- (void)remoteControlReceivedWithEvent:(UIEvent *)event { [[TNPlayer shared] handleRemoteEvent:event]; }

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return TNIsPad() ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait; }
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return TNIsPad() || o == UIInterfaceOrientationPortrait; }

#pragma mark - Layout

- (BOOL)showsPlayerBar { return TNIsPad() || [TNPlayer shared].currentTrack != nil; }

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGSize s = self.view.bounds.size;
    BOOL bar = [self showsPlayerBar];
    self.playerBar.hidden = !bar;
    // the home indicator of iOS 11+ (zero elsewhere): the bottom bar grows over it, its content stays above
    CGFloat home = TNSafeAreaInsets(self.view).bottom;
    if (TNIsPad()) {
        CGFloat barH = [TNPlayerBar heightCompact:NO];
        CGFloat side = s.width > s.height ? 250 : 220;
        self.sidebar.view.frame = CGRectMake(0, 0, side, s.height - barH - home);
        self.divider.frame = CGRectMake(side, 0, 1, s.height - barH - home);
        self.current.view.frame = CGRectMake(side + 1, 0, s.width - side - 1, s.height - barH - home);
        self.playerBar.frame = CGRectMake(0, s.height - barH - home, s.width, barH + home);
        self.playerBar.bottomInset = home;
    } else {
        CGFloat tabH = 49 + home, barH = bar ? [TNPlayerBar heightCompact:YES] : 0;
        self.tabBar.frame = CGRectMake(0, s.height - tabH, s.width, tabH);   // (the items sit above the indicator by themselves)
        self.playerBar.frame = CGRectMake(0, s.height - tabH - barH, s.width, [TNPlayerBar heightCompact:YES]);
        self.playerBar.bottomInset = 0;
        self.current.view.frame = CGRectMake(0, 0, s.width, s.height - tabH - barH);
    }
}

#pragma mark - Sections

- (UIViewController *)rootControllerFor:(TNSection)section
{
    switch (section) {
        case TNSectionHome: return [[TNHomeViewController alloc] init];
        case TNSectionExplore: return [[TNBrowseViewController alloc] initWithBrowseId:@"FEmusic_explore" params:nil title:L(@"Explore")];
        case TNSectionSearch: return [[TNSearchViewController alloc] init];
        case TNSectionLiked: return [[TNTrackListViewController alloc] initLikedSongs];
        case TNSectionPlaylists: return [[TNLibraryViewController alloc] initWithMode:TNLibraryPlaylists switcher:NO];
        case TNSectionAlbums: return [[TNLibraryViewController alloc] initWithMode:TNLibraryAlbums switcher:NO];
        case TNSectionArtists: return [[TNLibraryViewController alloc] initWithMode:TNLibraryArtists switcher:NO];
        case TNSectionRecent: return [[TNTrackListViewController alloc] initRecent];
        case TNSectionApple: return [[TNLibraryViewController alloc] initWithMode:TNLibraryApple switcher:NO];
        case TNSectionSettings: return [[TNSettingsViewController alloc] init];
        case TNSectionLibrary: return [[TNLibraryViewController alloc] initWithMode:TNLibraryPlaylists switcher:YES];
    }
    return nil;
}

- (UINavigationController *)navFor:(TNSection)section
{
    UINavigationController *nav = self.navs[@(section)];
    if (!nav) {
        UIViewController *root = [self rootControllerFor:section];
        if (!root) return nil;
        nav = [[UINavigationController alloc] initWithRootViewController:root];
        [[TNTheme shared] applyToNavigationBar:nav.navigationBar];
        self.navs[@(section)] = nav;
    }
    return nav;
}

- (UINavigationController *)contentNavigationController { return self.current; }

- (void)showSection:(TNSection)section
{
    // (the iPhone has no tab for every part of the library: they open inside the Library tab)
    if (!TNIsPad() && (section == TNSectionLiked || section == TNSectionPlaylists || section == TNSectionAlbums ||
                       section == TNSectionArtists || section == TNSectionRecent || section == TNSectionApple)) {
        [self showSection:TNSectionLibrary];
        UIViewController *top = [self rootControllerFor:section];
        if (top && section != TNSectionPlaylists) [self.current pushViewController:top animated:NO];
        return;
    }
    UINavigationController *nav = [self navFor:section];
    if (!nav) return;
    if (nav == self.current) {
        // the section again: back to its first screen (Search: into the field)
        [nav popToRootViewControllerAnimated:YES];
        if (section == TNSectionSearch && [nav.viewControllers.firstObject isKindOfClass:[TNSearchViewController class]])
            [(TNSearchViewController *)nav.viewControllers.firstObject focusSearchField];
        return;
    }
    UINavigationController *old = self.current;
    [old willMoveToParentViewController:nil];
    [old.view removeFromSuperview];
    [old removeFromParentViewController];
    self.current = nav;
    self.section = section;
    [self addChildViewController:nav];
    [self.view insertSubview:nav.view belowSubview:self.playerBar];
    [nav didMoveToParentViewController:self];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self.sidebar selectSection:section];
    if (self.tabBar) {
        NSUInteger i = [self.tabSections indexOfObject:@(section)];
        if (i != NSNotFound) self.tabBar.selectedItem = self.tabBar.items[i];
    }
    if (section == TNSectionSearch && [nav.viewControllers.firstObject isKindOfClass:[TNSearchViewController class]] && nav.viewControllers.count == 1)
        [(TNSearchViewController *)nav.viewControllers.firstObject focusSearchField];
}

- (void)showSidebarPlaylist:(TNPlaylist *)playlist
{
    if (!playlist.playlistId.length) return;
    [self showSection:playlist.source == TNSourceApple ? TNSectionApple : TNSectionPlaylists];
    [self.current popToRootViewControllerAnimated:NO];
    [self.current pushViewController:[[TNTrackListViewController alloc] initWithPlaylist:playlist] animated:NO];
    [self.sidebar selectPlaylist:[playlist key]];
}

- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item
{
    NSUInteger i = (NSUInteger)item.tag;
    if (i < self.tabSections.count) [self showSection:(TNSection)[self.tabSections[i] integerValue]];
}

#pragma mark - Going places

- (UIViewController *)presentedTop
{
    UIViewController *top = self;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    return top;
}

- (void)pushViewController:(UIViewController *)controller
{
    if (!controller) return;
    if (self.presentedViewController) {
        UINavigationController *nav = self.current;
        [self dismissViewControllerAnimated:YES completion:^{ [nav pushViewController:controller animated:YES]; }];
        return;
    }
    [self.current pushViewController:controller animated:YES];
}

- (void)presentNowPlaying { [self presentNowPlayingPanel:TNNowPlayingArt]; }

- (void)presentNowPlayingPanel:(NSInteger)panel
{
    if (![TNPlayer shared].currentTrack) { [self showToast:L(@"Nothing playing")]; return; }
    UIViewController *top = [self presentedTop];
    if ([top isKindOfClass:[TNNowPlayingViewController class]]) { ((TNNowPlayingViewController *)top).panel = (TNNowPlayingPanel)panel; return; }
    TNNowPlayingViewController *np = [[TNNowPlayingViewController alloc] init];
    np.panel = (TNNowPlayingPanel)panel;
    np.modalPresentationStyle = UIModalPresentationFullScreen;   // (iOS 13 and newer would present a card)
    np.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    [top presentViewController:np animated:YES completion:nil];
}

- (void)showQueue { [self presentNowPlayingPanel:TNNowPlayingQueue]; }
- (void)showLyrics { [self presentNowPlayingPanel:TNNowPlayingLyrics]; }

- (void)presentSheet:(UIViewController *)controller
{
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    [[TNTheme shared] applyToNavigationBar:nav.navigationBar];
    if (TNIsPad()) nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [[self presentedTop] presentViewController:nav animated:YES completion:nil];
}

- (UIViewController *)topController
{
    UIViewController *top = [self presentedTop];
    if (top == self) top = self.current;
    if ([top isKindOfClass:[UINavigationController class]]) top = [(UINavigationController *)top topViewController];
    return top;
}

- (void)goBack
{
    UIViewController *top = [self presentedTop];
    if (top != self) { [top.presentingViewController dismissViewControllerAnimated:YES completion:nil]; return; }
    [self.current popViewControllerAnimated:YES];
}

#pragma mark - Toast

- (void)showToast:(NSString *)text
{
    if (!text.length) return;
    UIWindow *window = self.view.window;
    if (!window) return;
    if (!self.toast) {
        self.toast = [[UILabel alloc] initWithFrame:CGRectZero];
        self.toast.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        self.toast.textColor = [UIColor whiteColor];
        self.toast.font = [[TNTheme shared] boldBodyFont];
        self.toast.textAlignment = NSTextAlignmentCenter;
        self.toast.numberOfLines = 3;
        self.toast.layer.cornerRadius = 10;
        self.toast.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        self.toast.layer.borderWidth = 1;
        self.toast.clipsToBounds = YES;
        self.toast.userInteractionEnabled = NO;
    }
    // (on the view on top, so it shows over the full player and sheets too, turned with the interface)
    UIView *host = [self presentedTop].view;
    [host addSubview:self.toast];
    self.toast.text = text;
    CGSize size = [text sizeWithFont:self.toast.font constrainedToSize:CGSizeMake(MIN(host.bounds.size.width - 60, 420), 200)];
    CGFloat w = ceilf(size.width) + 40, h = ceilf(size.height) + 24;
    CGFloat bottomBars = ([self showsPlayerBar] ? (TNIsPad() ? 72 : 54) : 0) + (self.tabBar ? 49 : 0) + TNSafeAreaInsets(self.view).bottom;
    CGFloat y = host == self.view ? host.bounds.size.height - bottomBars - h - 24 : host.bounds.size.height * 0.75 - h / 2;
    self.toast.frame = CGRectIntegral(CGRectMake((host.bounds.size.width - w) / 2, y, w, h));
    self.toast.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    self.toast.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ self.toast.alpha = 1; }];
    NSUInteger generation = ++self.toastGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.toastGeneration) return;
        [UIView animateWithDuration:0.3 animations:^{ self.toast.alpha = 0; } completion:^(BOOL finished) {
            if (generation == self.toastGeneration) [self.toast removeFromSuperview];
        }];
    });
}

#pragma mark - State

- (void)playerChanged
{
    if (!TNIsPad() && self.playerBar.hidden == [self showsPlayerBar]) {
        [UIView animateWithDuration:0.25 animations:^{ [self.view setNeedsLayout]; [self.view layoutIfNeeded]; }];
    }
}

- (void)playerFailed:(NSNotification *)note
{
    NSError *error = note.userInfo[@"error"];
    if (error.localizedDescription.length) [self showToast:error.localizedDescription];
}

@end
