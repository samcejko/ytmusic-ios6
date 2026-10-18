#import "TNAppleConnectViewController.h"
#import "TNAppleMusic.h"
#import "TNPairServer.h"
#import "TNRouter.h"
#import "TNTheme.h"
#import "TNCommon.h"

@interface TNAppleConnectViewController () <UITextViewDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView *mark;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *introLabel;
@property (nonatomic, strong) UILabel *computerHeader;
@property (nonatomic, strong) UILabel *addressLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *pasteHeader;
@property (nonatomic, strong) UITextView *tokenView;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UILabel *stepsLabel;
@property (nonatomic) BOOL busy;
@end

@implementation TNAppleConnectViewController

- (UILabel *)label:(UIFont *)font color:(UIColor *)color
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = font;
    l.textColor = color;
    l.backgroundColor = [UIColor clearColor];
    l.numberOfLines = 0;
    [self.scroll addSubview:l];
    return l;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    TNTheme *theme = [TNTheme shared];
    self.title = L(@"Apple Music");
    self.view.backgroundColor = [theme backgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Connect") style:UIBarButtonItemStyleDone target:self action:@selector(connectPasted)];
    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self.view addSubview:self.scroll];
    self.mark = [[UIImageView alloc] initWithImage:[theme appleMarkWithSize:64]];
    [self.scroll addSubview:self.mark];
    self.titleLabel = [self label:[theme headerFont] color:[theme primaryTextColor]];
    self.titleLabel.text = L(@"Connect Apple Music");
    self.introLabel = [self label:[theme bodyFont] color:[theme secondaryTextColor]];
    self.introLabel.text = L(@"Muzika reads your Apple Music playlists (nothing else) and plays them from YouTube Music. It needs the token music.apple.com keeps after you sign in there; it stays on this device.");
    self.computerHeader = [self label:[theme sectionFont] color:[theme secondaryTextColor]];
    self.computerHeader.text = [L(@"From a computer on this Wi-Fi") uppercaseString];
    self.addressLabel = [self label:[UIFont fontWithName:@"HelveticaNeue-Bold" size:TNIsPad() ? 22 : 18] ?: [UIFont boldSystemFontOfSize:20] color:[theme accentTextColor]];
    self.statusLabel = [self label:[theme smallFont] color:[theme secondaryTextColor]];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.hidesWhenStopped = YES;
    [self.scroll addSubview:self.spinner];
    self.pasteHeader = [self label:[theme sectionFont] color:[theme secondaryTextColor]];
    self.pasteHeader.text = [L(@"Or paste it here") uppercaseString];
    self.tokenView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.tokenView.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    self.tokenView.textColor = [theme primaryTextColor];
    self.tokenView.font = [UIFont fontWithName:@"Courier" size:12] ?: [UIFont systemFontOfSize:12];
    self.tokenView.layer.cornerRadius = 6;
    self.tokenView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    self.tokenView.layer.borderWidth = 1;
    self.tokenView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.tokenView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.tokenView.keyboardAppearance = UIKeyboardAppearanceAlert;
    [self.scroll addSubview:self.tokenView];
    self.connectButton = [theme accentButtonWithTitle:L(@"Connect")];
    [self.connectButton addTarget:self action:@selector(connectPasted) forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:self.connectButton];

    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    toolbar.barStyle = UIBarStyleBlackTranslucent;
    UIBarButtonItem *connectBarBtn = [[UIBarButtonItem alloc] initWithTitle:L(@"Connect") style:UIBarButtonItemStyleDone target:self action:@selector(connectPasted)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self.tokenView action:@selector(resignFirstResponder)];
    toolbar.items = @[connectBarBtn, flex, doneBtn];
    self.tokenView.inputAccessoryView = toolbar;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self.tokenView action:@selector(resignFirstResponder)];
    tap.cancelsTouchesInView = NO;
    [self.scroll addGestureRecognizer:tap];

    self.stepsLabel = [self label:[theme smallFont] color:[theme tertiaryTextColor]];
    self.stepsLabel.text = [NSString stringWithFormat:@"%@\n1. %@\n2. %@\n3. %@",
                            L(@"Where the token is:"),
                            L(@"Open music.apple.com in this browser and sign in."),
                            L(@"Open the developer tools (F12) > Application (Chrome, Edge) or Storage (Firefox) > Cookies > https://music.apple.com."),
                            L(@"Copy the value of the cookie media-user-token.")];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];

    __weak TNAppleConnectViewController *weakSelf = self;
    BOOL running = [[TNPairServer shared] startWithHandler:^(NSString *token) { [weakSelf connectWithToken:token]; }];
    if (running) {
        self.addressLabel.text = [TNPairServer shared].address;
        self.statusLabel.text = L(@"Open this address in the browser of a computer (or a phone) on the same Wi-Fi and follow the steps there.");
    } else {
        self.addressLabel.text = @"";
        self.statusLabel.text = L(@"This device is not on a Wi-Fi network: paste the token below.");
    }
    [self.view setNeedsLayout];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
    [[TNPairServer shared] stop];
}

- (void)keyboardWillShow:(NSNotification *)note
{
    NSDictionary *info = [note userInfo];
    CGRect kbFrame = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbFrameConverted = [self.view convertRect:kbFrame fromView:nil];
    CGFloat kbHeight = kbFrameConverted.size.height;

    NSTimeInterval duration = [[info objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = (UIViewAnimationCurve)[[info objectForKey:UIKeyboardAnimationCurveUserInfoKey] integerValue];

    UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, kbHeight, 0);
    CGFloat targetOffsetY = CGRectGetMaxY(self.connectButton.frame) + 16 - (self.scroll.bounds.size.height - kbHeight);
    if (targetOffsetY > 0) {
        [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
            self.scroll.contentInset = insets;
            self.scroll.scrollIndicatorInsets = insets;
            self.scroll.contentOffset = CGPointMake(0, targetOffsetY);
        } completion:nil];
    } else {
        [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
            self.scroll.contentInset = insets;
            self.scroll.scrollIndicatorInsets = insets;
        } completion:nil];
    }
}

- (void)keyboardWillHide:(NSNotification *)note
{
    NSDictionary *info = [note userInfo];
    NSTimeInterval duration = [[info objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = (UIViewAnimationCurve)[[info objectForKey:UIKeyboardAnimationCurveUserInfoKey] integerValue];

    [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
        self.scroll.contentInset = UIEdgeInsetsZero;
        self.scroll.scrollIndicatorInsets = UIEdgeInsetsZero;
    } completion:nil];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = TNIsPad() ? 34 : 16, cw = w - pad * 2;
    CGFloat y = pad;
    self.mark.frame = CGRectMake(pad, y, 64, 64);
    self.titleLabel.frame = CGRectMake(pad + 78, y + 14, cw - 78, 36);
    y += 80;
    y = [self place:self.introLabel at:y width:cw x:pad] + 18;
    y = [self place:self.computerHeader at:y width:cw x:pad] + 6;
    y = [self place:self.addressLabel at:y width:cw x:pad] + 4;
    y = [self place:self.statusLabel at:y width:cw - 30 x:pad];
    self.spinner.center = CGPointMake(pad + cw - 10, y - 10);
    y += 22;
    y = [self place:self.pasteHeader at:y width:cw x:pad] + 6;
    self.tokenView.frame = CGRectMake(pad, y, cw, 90);
    y += 100;
    self.connectButton.frame = CGRectMake(pad, y, [[TNTheme shared] widthForButton:self.connectButton minimum:120], 32);
    y += 48;
    y = [self place:self.stepsLabel at:y width:cw x:pad] + pad;
    self.scroll.contentSize = CGSizeMake(w, y);
}

- (CGFloat)place:(UILabel *)label at:(CGFloat)y width:(CGFloat)width x:(CGFloat)x
{
    CGSize s = [label.text ?: @"" sizeWithFont:label.font constrainedToSize:CGSizeMake(width, 600) lineBreakMode:NSLineBreakByWordWrapping];
    label.frame = CGRectMake(x, y, width, ceilf(s.height));
    return y + ceilf(s.height);
}

- (void)close
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)connectPasted
{
    [self.tokenView resignFirstResponder];
    [self connectWithToken:self.tokenView.text];
}

- (void)connectWithToken:(NSString *)token
{
    if (self.busy) return;
    self.busy = YES;
    self.connectButton.enabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self.spinner startAnimating];
    self.statusLabel.text = L(@"Checking the token with Apple…");
    [self.view setNeedsLayout];
    __weak TNAppleConnectViewController *weakSelf = self;
    [[TNAppleMusic shared] connectWithToken:token completion:^(NSError *error) {
        TNAppleConnectViewController *me = weakSelf;
        me.busy = NO;
        me.connectButton.enabled = YES;
        me.navigationItem.rightBarButtonItem.enabled = YES;
        [me.spinner stopAnimating];
        if (error) {
            me.statusLabel.text = error.localizedDescription;
            [me.view setNeedsLayout];
            return;
        }
        [TNRouter toast:L(@"Apple Music connected. Your playlists are syncing.")];
        [me close];
    }];
}

@end
