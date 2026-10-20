#import "TNListViewController.h"
#import "TNTheme.h"
#import "TNPlayer.h"
#import "TNCommon.h"

// Only instances of the dynamically discovered UIKit class receive these messages.
@protocol TNRefreshWidget <NSObject>
- (void)setTintColor:(UIColor *)color;
- (void)endRefreshing;
@end

@interface TNListViewController ()
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL refreshing;
@property (nonatomic, strong) UIControl<TNRefreshWidget> *refreshWidget;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic) BOOL loadedOnce;
@end

@implementation TNListViewController

- (instancetype)initWithStyle:(UITableViewStyle)style
{
    if ((self = [super initWithStyle:style])) _refreshable = YES;
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    TNTheme *theme = [TNTheme shared];
    [theme applyToTableView:self.tableView];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.backgroundColor = [UIColor clearColor];
    self.messageLabel.textColor = [theme secondaryTextColor];
    self.messageLabel.font = [theme bodyFont];
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.textAlignment = UITextAlignmentCenter;
    self.messageLabel.hidden = YES;
    [self.view addSubview:self.messageLabel];
    self.retryButton = [theme outlineButtonWithTitle:L(@"Try again")];
    [self.retryButton addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;
    [self.view addSubview:self.retryButton];
    if (self.refreshable) {
        Class refreshClass = NSClassFromString(@"UIRefreshControl");
        if (refreshClass && [self respondsToSelector:@selector(setRefreshControl:)]) {
            self.refreshWidget = [[refreshClass alloc] init];
            [self.refreshWidget setTintColor:[theme secondaryTextColor]];
            [self.refreshWidget addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
            [self performSelector:@selector(setRefreshControl:) withObject:self.refreshWidget];
        } else {
            NSMutableArray *items = [NSMutableArray arrayWithArray:self.navigationItem.rightBarButtonItems ?: @[]];
            [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                       target:self action:@selector(reload)]];
            self.navigationItem.rightBarButtonItems = items;
        }
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged) name:TNPlayerDidChangeNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (!self.loadedOnce) {
        self.loadedOnce = YES;
        [self load];
    }
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat top = b.origin.y + MIN(b.size.height / 3, 220);
    self.spinner.center = CGPointMake(CGRectGetMidX(b), top);
    self.messageLabel.frame = CGRectMake(30, top - 40, b.size.width - 60, 80);
    self.retryButton.frame = CGRectMake(CGRectGetMidX(b) - 80, top + 50, 160, 34);
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return TNIsPad() ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskPortrait; }

- (void)load { [self finishLoadingWithError:nil empty:NO emptyMessage:nil]; }

- (void)reload
{
    self.refreshing = YES;
    [self load];
}

- (void)startLoading
{
    self.loading = YES;
    self.messageLabel.hidden = YES;
    self.retryButton.hidden = YES;
    if (!(self.refreshing && self.refreshWidget) && [self.tableView numberOfSections] == 0) [self.spinner startAnimating];
    else if (!(self.refreshing && self.refreshWidget) && [self tableView:self.tableView numberOfRowsInSection:0] == 0) [self.spinner startAnimating];
}

- (void)finishLoadingWithError:(NSError *)error empty:(BOOL)empty emptyMessage:(NSString *)message
{
    self.loading = NO;
    self.refreshing = NO;
    [self.spinner stopAnimating];
    [self.refreshWidget endRefreshing];
    [self.tableView reloadData];
    if (empty || (error && !empty && [self.tableView numberOfSections] == 0)) {
        self.messageLabel.text = error ? error.localizedDescription : message;
        self.messageLabel.hidden = !self.messageLabel.text.length;
        self.retryButton.hidden = !error;
    } else {
        self.messageLabel.hidden = YES;
        self.retryButton.hidden = YES;
    }
    [self.view setNeedsLayout];
}

- (void)playerChanged
{
    if (!self.isViewLoaded || !self.view.window) return;
    // (the rows first, reloaded afterwards in one go: on iOS 6 visibleCells is the table's own array, and reloading
    // a row while going through it throws "mutated while being enumerated")
    NSMutableArray *rows = [NSMutableArray array];
    for (UITableViewCell *cell in [self.tableView.visibleCells copy]) {
        NSIndexPath *ip = [self.tableView indexPathForCell:cell];
        if (ip && [cell respondsToSelector:@selector(showTrack:number:)]) [rows addObject:ip];
    }
    if (rows.count) [self.tableView reloadRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationNone];
}

@end
