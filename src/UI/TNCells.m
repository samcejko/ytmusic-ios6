#import "TNDownloads.h"
#import "TNCells.h"
#import "TNTheme.h"
#import "TNImageLoader.h"
#import "TNModels.h"
#import "TNPlayer.h"
#import "TNUtils.h"
#import "TNCommon.h"

UIView *TNSectionHeader(NSString *title, CGFloat width)
{
    return TNSectionHeaderWithMore(title, width, nil, NULL, 0);
}

UIView *TNSectionHeaderWithMore(NSString *title, CGFloat width, id target, SEL action, NSInteger tag)
{
    TNTheme *theme = [TNTheme shared];
    UIImageView *bar = [[UIImageView alloc] initWithImage:[theme sectionHeaderImage]];
    bar.frame = CGRectMake(0, 0, width, 26);
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.userInteractionEnabled = YES;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, width - (target ? 96 : 24), 26)];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    l.backgroundColor = [UIColor clearColor];
    l.font = [theme sectionFont];
    l.textColor = [theme secondaryTextColor];
    l.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    l.shadowOffset = CGSizeMake(0, -1);
    l.text = [title uppercaseString];
    [bar addSubview:l];
    if (target && action) {
        UIButton *more = [UIButton buttonWithType:UIButtonTypeCustom];
        [more setTitle:[L(@"More") uppercaseString] forState:UIControlStateNormal];
        more.titleLabel.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:11] ?: [UIFont boldSystemFontOfSize:11];
        [more setTitleColor:[theme primaryTextColor] forState:UIControlStateNormal];
        [more setBackgroundImage:[theme outlineButtonImageHighlighted:NO] forState:UIControlStateNormal];
        [more setBackgroundImage:[theme outlineButtonImageHighlighted:YES] forState:UIControlStateHighlighted];
        CGFloat w = [theme widthForButton:more minimum:64];
        more.frame = CGRectMake(width - w - 8, 2, w, 22);
        more.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        more.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
        more.tag = tag;
        [more addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:more];
    }
    return bar;
}

#pragma mark - Song

@interface TNTrackCell ()
@property (nonatomic, strong) TNImageView *art;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UILabel *numberLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UIImageView *explicitView;
@property (nonatomic, strong) UIImageView *warningView;
@property (nonatomic, strong) UIImageView *downloadedView;
@property (nonatomic, strong) UIImageView *playingView;
@end

@implementation TNTrackCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        TNTheme *theme = [TNTheme shared];
        [theme styleCell:self];
        _showsArt = YES;
        _showsAlbum = YES;
        _art = [[TNImageView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        [self.contentView addSubview:_art];
        _numberLabel = [self label:[theme smallFont] color:[theme secondaryTextColor]];
        _numberLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel = [self label:[theme bodyFont] color:[theme primaryTextColor]];
        _subtitleLabel = [self label:[theme smallFont] color:[theme secondaryTextColor]];
        _durationLabel = [self label:[theme smallFont] color:[theme tertiaryTextColor]];
        _durationLabel.textAlignment = NSTextAlignmentRight;
        _explicitView = [[UIImageView alloc] initWithImage:[theme explicitBadge]];
        [self.contentView addSubview:_explicitView];
        _warningView = [[UIImageView alloc] initWithImage:[theme icon:TNIconWarning size:14 color:[theme accentTextColor]]];
        [self.contentView addSubview:_warningView];
        _downloadedView = [[UIImageView alloc] initWithImage:[theme icon:TNIconDownloaded size:14 color:[theme accentTextColor]]];
        [self.contentView addSubview:_downloadedView];
        _playingView = [[UIImageView alloc] initWithImage:[theme icon:TNIconSpeaker size:16 color:[theme accentTextColor]]];
        [self.contentView addSubview:_playingView];
        _moreButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_moreButton setImage:[theme icon:TNIconMore size:18 color:[theme secondaryTextColor]] forState:UIControlStateNormal];
        _moreButton.accessibilityLabel = L(@"More");
        [self.contentView addSubview:_moreButton];
    }
    return self;
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = font;
    l.textColor = color;
    l.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:l];
    return l;
}

- (void)showTrack:(TNTrack *)track number:(NSInteger)number
{
    TNTheme *theme = [TNTheme shared];
    BOOL playing = [[TNPlayer shared] isCurrent:track];
    self.titleLabel.text = [TNUtils displayText:track.name];
    self.titleLabel.textColor = playing ? [theme accentTextColor] : (track.playable ? [theme primaryTextColor] : [theme tertiaryTextColor]);
    NSString *sub = [track artistNames] ?: @"";
    if (self.showsAlbum && self.showsArt && track.album.name.length) sub = sub.length ? [NSString stringWithFormat:@"%@ • %@", sub, track.album.name] : track.album.name;
    if (track.matchFailed && !track.videoId.length) sub = [NSString stringWithFormat:@"%@ • %@", L(@"Not found on YouTube"), sub];
    else if (track.isVideo && ![track isApple]) sub = sub.length ? [NSString stringWithFormat:@"%@ • %@", L(@"Video"), sub] : L(@"Video");
    self.subtitleLabel.text = [TNUtils displayText:sub];
    self.durationLabel.text = track.durationMs ? TNFormatDurationMs(track.durationMs) : @"";
    self.numberLabel.text = number > 0 ? [NSString stringWithFormat:@"%ld", (long)number] : @"";
    self.explicitView.hidden = !track.explicitContent;
    self.warningView.hidden = !(track.matchFailed && !track.videoId.length);
    self.downloadedView.hidden = ![[TNDownloads shared] isDownloaded:track];
    self.playingView.hidden = !playing;
    self.art.hidden = !self.showsArt;
    self.numberLabel.hidden = self.showsArt || playing;
    if (self.showsArt) [self.art setImageURL:[track imageURLForSize:80] placeholder:[theme artPlaceholderWithSize:40]];
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize s = self.contentView.bounds.size;
    CGFloat x = 10;
    if (self.showsArt) {
        self.art.frame = CGRectMake(x, floorf((s.height - 40) / 2), 40, 40);
        x += 50;
    } else {
        self.numberLabel.frame = CGRectMake(4, 0, 34, s.height);
        x = 42;
    }
    self.playingView.frame = self.showsArt ? CGRectMake(x - 4, floorf((s.height - 16) / 2), 16, 16) : CGRectMake(13, floorf((s.height - 16) / 2), 16, 16);
    if (self.showsArt && !self.playingView.hidden) x += 16;
    self.moreButton.frame = CGRectMake(s.width - 40, 0, 40, s.height);
    CGFloat right = self.moreButton.hidden ? s.width - 6 : s.width - 40;
    CGSize d = [self.durationLabel.text sizeWithFont:self.durationLabel.font];
    self.durationLabel.frame = CGRectMake(right - ceilf(d.width) - 4, 0, ceilf(d.width), s.height);
    right -= ceilf(d.width) + 12;
    CGFloat textX = x;
    if (!self.warningView.hidden) {
        self.warningView.frame = CGRectMake(textX, floorf(s.height / 2) + 4, 14, 14);
        textX += 18;
    }
    if (!self.downloadedView.hidden) {
        self.downloadedView.frame = CGRectMake(textX, floorf(s.height / 2) + 4, 14, 14);
        textX += 18;
    }
    if (!self.explicitView.hidden) {
        self.explicitView.frame = CGRectMake(textX, floorf(s.height / 2) + 4, 14, 14);
        textX += 18;
    }
    self.titleLabel.frame = CGRectMake(x, floorf(s.height / 2) - 19, right - x, 20);
    self.subtitleLabel.frame = CGRectMake(textX, floorf(s.height / 2) + 2, right - textX, 17);
}

@end

#pragma mark - Media

@interface TNMediaCell ()
@property (nonatomic, strong) TNImageView *art;
@end

@implementation TNMediaCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier])) {
        TNTheme *theme = [TNTheme shared];
        [theme styleCell:self];
        self.textLabel.font = [theme boldBodyFont];
        self.detailTextLabel.font = [theme smallFont];
        _art = [[TNImageView alloc] initWithFrame:CGRectMake(0, 0, 52, 52)];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        [self.contentView addSubview:_art];
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}

- (void)setRound:(BOOL)round
{
    _round = round;
    self.art.layer.cornerRadius = round ? 26 : 0;
}

- (void)showTitle:(NSString *)title subtitle:(NSString *)subtitle imageURL:(NSString *)url
{
    TNTheme *theme = [TNTheme shared];
    self.textLabel.text = [TNUtils displayText:title];
    self.detailTextLabel.text = [TNUtils displayText:subtitle];
    self.art.contentMode = UIViewContentModeScaleAspectFill;
    [self.art setImageURL:url placeholder:self.round ? [theme artistPlaceholderWithSize:52] : [theme artPlaceholderWithSize:52]];
}

- (void)showItem:(id)item
{
    self.round = [item isKindOfClass:[TNArtist class]];
    NSString *url = TNImageOf(item, 120);
    [self showTitle:TNTitleOf(item) subtitle:TNSubtitleOf(item) imageURL:url];
    if (!url && [item isKindOfClass:[TNPlaylist class]] && ((TNPlaylist *)item).source == TNSourceApple) {
        self.art.image = [[TNTheme shared] appleMarkWithSize:52];
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize s = self.contentView.bounds.size;
    self.art.frame = CGRectMake(10, floorf((s.height - 52) / 2), 52, 52);
    CGFloat x = 74, w = s.width - x - 6;
    self.textLabel.frame = CGRectMake(x, floorf(s.height / 2) - 20, w, 20);
    self.detailTextLabel.frame = CGRectMake(x, floorf(s.height / 2) + 2, w, 18);
}

@end

#pragma mark - Cards

@interface TNCardView ()
@property (nonatomic, strong) TNImageView *art;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation TNCardView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        TNTheme *theme = [TNTheme shared];
        _art = [[TNImageView alloc] initWithFrame:CGRectZero];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        _art.userInteractionEnabled = NO;
        [self addSubview:_art];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:13] ?: [UIFont boldSystemFontOfSize:13];
        _titleLabel.textColor = [theme primaryTextColor];
        _titleLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:_titleLabel];
        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.font = [UIFont fontWithName:@"HelveticaNeue" size:12] ?: [UIFont systemFontOfSize:12];
        _subtitleLabel.textColor = [theme secondaryTextColor];
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:_subtitleLabel];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    self.art.alpha = highlighted ? 0.6 : 1;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.wide ? floorf(w * 9 / 16) : w;
    self.art.frame = CGRectMake(0, w - h, w, h);
    self.art.layer.cornerRadius = self.round ? w / 2 : 0;
    self.titleLabel.frame = CGRectMake(0, w + 6, w, 17);
    self.subtitleLabel.frame = CGRectMake(0, w + 23, w, 16);
    self.titleLabel.textAlignment = self.round ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    self.subtitleLabel.textAlignment = self.titleLabel.textAlignment;
}

@end

@interface TNShelfCell ()
@property (nonatomic, strong) UIScrollView *scroller;
@property (nonatomic, strong) NSMutableArray *cards;
@end

@implementation TNShelfCell

+ (CGFloat)heightForCardWidth:(CGFloat)width { return width + 58; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _scroller = [[UIScrollView alloc] initWithFrame:self.contentView.bounds];
        _scroller.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scroller.showsHorizontalScrollIndicator = NO;
        _scroller.alwaysBounceHorizontal = YES;
        _scroller.scrollsToTop = NO;
        [self.contentView addSubview:_scroller];
        _cards = [NSMutableArray array];
    }
    return self;
}

- (void)showItems:(NSArray *)items cardWidth:(CGFloat)width
{
    TNTheme *theme = [TNTheme shared];
    while (self.cards.count < items.count) {
        TNCardView *card = [[TNCardView alloc] initWithFrame:CGRectZero];
        [card addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.scroller addSubview:card];
        [self.cards addObject:card];
    }
    CGFloat x = 12, gap = 14;
    for (NSUInteger i = 0; i < self.cards.count; i++) {
        TNCardView *card = self.cards[i];
        card.hidden = i >= items.count;
        if (card.hidden) continue;
        id item = items[i];
        card.round = [item isKindOfClass:[TNArtist class]];
        card.wide = [item isKindOfClass:[TNTrack class]] && ((TNTrack *)item).isVideo;
        card.item = item;
        card.titleLabel.text = [TNUtils displayText:TNTitleOf(item)];
        NSString *sub = TNSubtitleOf(item);
        if ([item isKindOfClass:[TNTrack class]]) sub = [(TNTrack *)item artistNames];
        if ([item isKindOfClass:[TNAlbum class]]) {
            TNAlbum *a = item;
            sub = a.year.length && [a artistNames].length ? [NSString stringWithFormat:@"%@ • %@", a.year, [a artistNames]] : ([a artistNames].length ? [a artistNames] : a.year);
        }
        card.subtitleLabel.text = [TNUtils displayText:sub];
        NSString *url = TNImageOf(item, card.wide ? 480 : 300);
        [card.art setImageURL:url placeholder:card.round ? [theme artistPlaceholderWithSize:width] : [theme artPlaceholderWithSize:width]];
        if (!url && [item isKindOfClass:[TNPlaylist class]] && ((TNPlaylist *)item).source == TNSourceApple) card.art.image = [theme appleMarkWithSize:width];
        card.frame = CGRectMake(x, 10, width, width + 44);
        [card setNeedsLayout];
        x += width + gap;
    }
    self.scroller.contentSize = CGSizeMake(x, width + 54);
    self.scroller.contentOffset = CGPointZero;
}

- (void)tapped:(TNCardView *)card
{
    if (self.onSelect && card.item) self.onSelect(card.item);
}

@end

#pragma mark - Song grid

@interface TNGridSongView : UIControl
@property (nonatomic, strong) TNImageView *art;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UIImageView *playingView;
@property (nonatomic, strong) TNTrack *track;
@property (nonatomic) NSUInteger index;
@end

@implementation TNGridSongView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        TNTheme *theme = [TNTheme shared];
        _art = [[TNImageView alloc] initWithFrame:CGRectZero];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        _art.userInteractionEnabled = NO;
        [self addSubview:_art];
        _playingView = [[UIImageView alloc] initWithImage:[theme icon:TNIconSpeaker size:18 color:[UIColor whiteColor]]];
        _playingView.contentMode = UIViewContentModeCenter;
        _playingView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        [self addSubview:_playingView];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [theme bodyFont];
        _titleLabel.textColor = [theme primaryTextColor];
        _titleLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:_titleLabel];
        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.font = [theme smallFont];
        _subtitleLabel.textColor = [theme secondaryTextColor];
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:_subtitleLabel];
        _moreButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_moreButton setImage:[theme icon:TNIconMore size:16 color:[theme secondaryTextColor]] forState:UIControlStateNormal];
        _moreButton.accessibilityLabel = L(@"More");
        [self addSubview:_moreButton];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [[TNTheme shared] rowHighlightColor] : [UIColor clearColor];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    self.art.frame = CGRectMake(4, floorf((s.height - 44) / 2), 44, 44);
    self.playingView.frame = self.art.frame;
    self.moreButton.frame = CGRectMake(s.width - 34, 0, 34, s.height);
    self.titleLabel.frame = CGRectMake(58, floorf(s.height / 2) - 19, s.width - 58 - 36, 20);
    self.subtitleLabel.frame = CGRectMake(58, floorf(s.height / 2) + 2, s.width - 58 - 36, 17);
}

@end

@interface TNSongGridCell ()
@property (nonatomic, strong) UIScrollView *scroller;
@property (nonatomic, strong) NSMutableArray *songViews;
@end

@implementation TNSongGridCell

+ (CGFloat)heightForRows:(NSUInteger)rows { return 56 * (CGFloat)rows + 12; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _scroller = [[UIScrollView alloc] initWithFrame:self.contentView.bounds];
        _scroller.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scroller.showsHorizontalScrollIndicator = NO;
        _scroller.alwaysBounceHorizontal = YES;
        _scroller.scrollsToTop = NO;
        _scroller.decelerationRate = UIScrollViewDecelerationRateFast;
        [self.contentView addSubview:_scroller];
        _songViews = [NSMutableArray array];
    }
    return self;
}

- (void)showTracks:(NSArray *)tracks rows:(NSUInteger)rows columnWidth:(CGFloat)width
{
    TNTheme *theme = [TNTheme shared];
    rows = MAX((NSUInteger)1, rows);
    while (self.songViews.count < tracks.count) {
        TNGridSongView *v = [[TNGridSongView alloc] initWithFrame:CGRectZero];
        [v addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [v.moreButton addTarget:self action:@selector(moreTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.scroller addSubview:v];
        [self.songViews addObject:v];
    }
    CGFloat x = 6;
    for (NSUInteger i = 0; i < self.songViews.count; i++) {
        TNGridSongView *v = self.songViews[i];
        v.hidden = i >= tracks.count;
        if (v.hidden) continue;
        TNTrack *t = tracks[i];
        v.track = t;
        v.index = i;
        v.moreButton.tag = (NSInteger)i;
        BOOL playing = [[TNPlayer shared] isCurrent:t];
        v.titleLabel.text = [TNUtils displayText:t.name];
        v.titleLabel.textColor = playing ? [theme accentTextColor] : [theme primaryTextColor];
        NSString *sub = [t artistNames];
        if (t.plays.length) sub = sub.length ? [NSString stringWithFormat:@"%@ • %@", sub, t.plays] : t.plays;
        v.subtitleLabel.text = [TNUtils displayText:sub];
        v.playingView.hidden = !playing;
        [v.art setImageURL:[t imageURLForSize:88] placeholder:[theme artPlaceholderWithSize:44]];
        NSUInteger column = i / rows, row = i % rows;
        v.frame = CGRectMake(x + (CGFloat)column * width, 6 + 56 * (CGFloat)row, width - 6, 56);
        [v setNeedsLayout];
    }
    NSUInteger columns = (tracks.count + rows - 1) / rows;
    self.scroller.contentSize = CGSizeMake(x + (CGFloat)columns * width + 6, 56 * (CGFloat)rows + 12);
}

- (void)tapped:(TNGridSongView *)v
{
    if (self.onSelect && v.track) self.onSelect(v.track, v.index);
}

- (void)moreTapped:(UIButton *)sender
{
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.songViews.count) return;
    TNGridSongView *v = self.songViews[(NSUInteger)sender.tag];
    if (self.onMore && v.track) self.onMore(v.track, sender);
}

@end

#pragma mark - Mood and genre tiles

@interface TNTileView : UIControl
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *stripe;
@property (nonatomic, strong) id item;
@end

@implementation TNTileView

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        TNTheme *theme = [TNTheme shared];
        self.layer.cornerRadius = 6;
        self.clipsToBounds = YES;
        UIImageView *face = [[UIImageView alloc] initWithImage:[theme darkButtonImageHighlighted:NO]];
        face.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        face.tag = 3;
        [self addSubview:face];
        _stripe = [[UIView alloc] initWithFrame:CGRectZero];
        [self addSubview:_stripe];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont fontWithName:@"HelveticaNeue-Bold" size:TNIsPad() ? 15 : 14] ?: [UIFont boldSystemFontOfSize:15];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
        _titleLabel.shadowOffset = CGSizeMake(0, -1);
        [self addSubview:_titleLabel];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    ((UIImageView *)[self viewWithTag:3]).image = [[TNTheme shared] darkButtonImageHighlighted:highlighted];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    [self viewWithTag:3].frame = self.bounds;
    self.stripe.frame = CGRectMake(0, 0, 6, s.height);
    self.titleLabel.frame = CGRectMake(16, 0, s.width - 24, s.height);
}

@end

@interface TNTileRowCell ()
@property (nonatomic, strong) NSMutableArray *tiles;
@end

@implementation TNTileRowCell

+ (CGFloat)heightForWidth:(CGFloat)width columns:(NSInteger)columns { return 56; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _tiles = [NSMutableArray array];
    }
    return self;
}

- (void)showTiles:(NSArray *)tiles columns:(NSInteger)columns
{
    while (self.tiles.count < (NSUInteger)columns) {
        TNTileView *t = [[TNTileView alloc] initWithFrame:CGRectZero];
        [t addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:t];
        [self.tiles addObject:t];
    }
    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        TNTileView *t = self.tiles[i];
        t.hidden = i >= tiles.count || i >= (NSUInteger)columns;
        if (t.hidden) continue;
        id item = tiles[i];
        t.item = item;
        t.titleLabel.text = TNTitleOf(item);
        NSString *hex = [item isKindOfClass:[TNCategory class]] ? ((TNCategory *)item).colorHex : nil;
        t.stripe.backgroundColor = [TNUtils colorFromHex:hex] ?: [[TNTheme shared] accentColor];
    }
    self.tag = columns;
    [self setNeedsLayout];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    NSInteger columns = MAX(1, self.tag);
    CGSize s = self.contentView.bounds.size;
    CGFloat gap = 10, w = (s.width - gap - gap * (CGFloat)columns) / (CGFloat)columns, h = s.height - gap;
    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        UIView *t = self.tiles[i];
        t.frame = CGRectMake(floorf(gap + (CGFloat)i * (w + gap)), 5, floorf(w), floorf(h));
    }
}

- (void)tapped:(TNTileView *)tile
{
    if (self.onSelect && tile.item) self.onSelect(tile.item);
}

@end
