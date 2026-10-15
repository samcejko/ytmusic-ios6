#import "TNAppleChartsViewController.h"
#import "TNAppleMusic.h"
#import "TNMatcher.h"
#import "TNModels.h"
#import "TNCommon.h"

NSString * const TNAppleChartsBrowseId = @"muzika:apple-charts";

@interface TNAppleChartsViewController ()
@property (nonatomic, strong) TNHTTPTask *task;
@property (nonatomic) NSUInteger loads;
@end

@implementation TNAppleChartsViewController

- (instancetype)init
{
    return [super initWithBrowseId:nil params:nil title:L(@"Apple Music charts")];
}

- (void)dealloc { [_task cancel]; }

- (void)load
{
    [self.task cancel];
    [self startLoading];
    NSUInteger load = ++self.loads;
    __weak TNAppleChartsViewController *weakSelf = self;
    self.task = [[TNAppleMusic shared] chartsWithCompletion:^(NSArray *shelves, NSError *error) {
        TNAppleChartsViewController *me = weakSelf;
        if (!me || load != me.loads) return;
        for (TNShelf *s in shelves) if (s.songs) [[TNMatcher shared] applyTo:s.items];
        me.shelves = shelves ?: @[];
        [me finishLoadingWithError:me.shelves.count ? nil : error empty:!me.shelves.count emptyMessage:L(@"Nothing here.")];
    }];
}

@end
