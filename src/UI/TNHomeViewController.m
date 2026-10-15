#import "TNHomeViewController.h"
#import "TNLibrary.h"
#import "TNAppleMusic.h"
#import "TNModels.h"
#import "TNTheme.h"
#import "TNCommon.h"

@interface TNHomeViewController ()
@property (nonatomic, strong) NSArray *remoteShelves;
@property (nonatomic, strong) UILabel *greeting;
@end

@implementation TNHomeViewController

- (instancetype)init
{
    if ((self = [super initWithBrowseId:@"FEmusic_home" params:nil title:L(@"Home")])) _remoteShelves = @[];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 60)];
    self.greeting = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, self.view.bounds.size.width - 28, 36)];
    self.greeting.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.greeting.font = [[TNTheme shared] headerFont];
    self.greeting.textColor = [[TNTheme shared] primaryTextColor];
    self.greeting.backgroundColor = [UIColor clearColor];
    self.greeting.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    self.greeting.shadowOffset = CGSizeMake(0, -1);
    [header addSubview:self.greeting];
    self.tableView.tableHeaderView = header;
    self.greeting.text = [self greetingText];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(localChanged) name:TNAppleDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(localChanged) name:TNLibraryDidChangeNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (NSString *)greetingText
{
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSHourCalendarUnit fromDate:[NSDate date]];
    if (c.hour >= 4 && c.hour < 12) return L(@"Good morning");
    if (c.hour >= 12 && c.hour < 18) return L(@"Good afternoon");
    return L(@"Good evening");
}

- (void)load
{
    self.greeting.text = [self greetingText];
    [super load];
}

- (NSArray *)shelvesForLoaded:(NSArray *)loaded
{
    if (loaded.count) self.remoteShelves = loaded;
    NSMutableArray *shelves = [NSMutableArray array];
    NSArray *recent = [[TNLibrary shared] recentTracks];
    if (recent.count) {
        TNShelf *s = [[TNShelf alloc] init];
        s.title = L(@"Listen again");
        s.items = [recent subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)16, recent.count))];
        [shelves addObject:s];
    }
    NSMutableArray *apple = [NSMutableArray array];
    if ([[TNAppleMusic shared] connected]) [apple addObjectsFromArray:[[TNLibrary shared] applePlaylists]];
    for (TNPlaylist *p in [[TNLibrary shared] savedPlaylists]) if (p.source == TNSourceApple) [apple addObject:p];
    if (apple.count) {
        TNShelf *s = [[TNShelf alloc] init];
        s.title = L(@"Your Apple Music");
        s.items = apple;
        [shelves addObject:s];
    }
    [shelves addObjectsFromArray:self.remoteShelves ?: @[]];
    return shelves;
}

- (void)localChanged
{
    if (!self.isViewLoaded) return;
    self.shelves = [self shelvesForLoaded:nil];
    if (!self.loading) [self.tableView reloadData];
}

@end
