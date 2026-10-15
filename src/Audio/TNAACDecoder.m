#import "TNAACDecoder.h"
#import "TNAudioFile.h"
#import "TNCommon.h"
#import <AudioToolbox/AudioToolbox.h>

#define TNFourCC(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))

static const UInt32 TNMaxPacketFrames = 2048;          // AAC-LC packets are 1024 frames; room for HE-AAC's 2048
static const OSStatus TNNoMoreInput = 0x544e6e64;       // 'TNnd': the feeding callback has nothing more right now

static inline uint32_t TNBE32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3]; }
static inline uint64_t TNBE64(const uint8_t *p) { return ((uint64_t)TNBE32(p) << 32) | (uint64_t)TNBE32(p + 4); }
static inline uint16_t TNBE16(const uint8_t *p) { return (uint16_t)(((uint16_t)p[0] << 8) | p[1]); }

typedef struct {
    uint64_t offset;    // where the box starts
    uint64_t size;      // header included
    uint32_t type;
    uint32_t header;    // 8 or 16 bytes
} TNBox;

// The box header at `pos` (its bytes must lie below `limit`); NO when they are not there yet or it is broken
static BOOL TNReadBox(const uint8_t *bytes, uint64_t pos, uint64_t limit, TNBox *box)
{
    if (!bytes || pos + 8 > limit) return NO;
    uint64_t size = TNBE32(bytes + pos);
    uint32_t type = TNBE32(bytes + pos + 4);
    uint32_t header = 8;
    if (size == 1) {
        if (pos + 16 > limit) return NO;
        size = TNBE64(bytes + pos + 8);
        header = 16;
    } else if (size == 0) {
        size = limit - pos;
    }
    if (size < header) return NO;
    box->offset = pos;
    box->size = size;
    box->type = type;
    box->header = header;
    return YES;
}

// The first child of a type in [start, end)
static BOOL TNFindChild(const uint8_t *bytes, uint64_t start, uint64_t end, uint32_t type, TNBox *out)
{
    uint64_t p = start;
    TNBox b;
    while (p + 8 <= end && TNReadBox(bytes, p, end, &b)) {
        if (b.offset + b.size > end) return NO;
        if (b.type == type) { *out = b; return YES; }
        p += b.size;
    }
    return NO;
}

// An MPEG-4 descriptor's length (1 to 4 bytes of 7 bits); returns the bytes used, 0 when broken
static NSUInteger TNDescriptorLength(const uint8_t *p, const uint8_t *end, uint32_t *length)
{
    uint32_t n = 0;
    NSUInteger used = 0;
    while (p + used < end && used < 4) {
        uint8_t b = p[used++];
        n = (n << 7) | (b & 0x7f);
        if (!(b & 0x80)) { *length = n; return used; }
    }
    return 0;
}

typedef struct {
    const uint8_t *data;
    UInt32 size;
    UInt32 channels;
    BOOL given;
    AudioStreamPacketDescription description;
} TNPacketFeed;

// The converter asks for input: one packet per call, then "nothing more" until the next decode
static OSStatus TNFeedPacket(AudioConverterRef converter, UInt32 *ioPackets, AudioBufferList *ioData,
                             AudioStreamPacketDescription **outDescription, void *user)
{
    TNPacketFeed *feed = (TNPacketFeed *)user;
    if (feed->given || !feed->data) {
        *ioPackets = 0;
        return TNNoMoreInput;
    }
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mData = (void *)feed->data;
    ioData->mBuffers[0].mDataByteSize = feed->size;
    ioData->mBuffers[0].mNumberChannels = feed->channels;
    feed->description.mStartOffset = 0;
    feed->description.mVariableFramesInPacket = 0;
    feed->description.mDataByteSize = feed->size;
    if (outDescription) *outDescription = &feed->description;
    *ioPackets = 1;
    feed->given = YES;
    return noErr;
}

@interface TNAACDecoder ()
@property (nonatomic) int sampleRate;
@property (nonatomic) int channels;
@property (nonatomic) NSInteger bitrate;
@property (nonatomic) uint64_t frame;
@property (nonatomic) BOOL atEnd;
@property (nonatomic) BOOL starved;
@end

@implementation TNAACDecoder {
    TNAudioFile *_file;
    AudioConverterRef _converter;
    uint32_t _timescale;           // of the track (mdhd), usually the sample rate
    uint32_t _defaultDuration;     // trex
    uint32_t _defaultSize;
    NSData *_cookie;               // the ES descriptor
    uint64_t _dataStart;           // the first fragment
    uint64_t _scanPos;             // the next top-level box to look at
    // the fragment being played
    uint64_t *_offsets;
    uint32_t *_sizes;
    NSUInteger _sampleCount, _sampleIndex, _sampleCapacity;
    BOOL _resyncFrame;             // after a seek: the next fragment's start time sets the position
    // the index (sidx)
    NSMutableArray *_index;        // NSArray @[offset, startFrame] per subsegment
    // decoded frames not handed out yet
    int16_t *_pcm;
    NSUInteger _pcmCount, _pcmIndex;
}

- (instancetype)initWithFile:(TNAudioFile *)file
{
    if ((self = [super init])) {
        _file = file;
        _pcm = malloc(TNMaxPacketFrames * 2 * sizeof(int16_t));
        _index = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc
{
    if (_converter) AudioConverterDispose(_converter);
    free(_offsets);
    free(_sizes);
    free(_pcm);
}

#pragma mark - Opening

// Waits for the bytes up to `end` (the download comes in at its own pace); NO when they will not come
- (BOOL)need:(uint64_t)end timeout:(NSTimeInterval)timeout
{
    if (_file.length && end > _file.length) return NO;
    if (_file.available >= end) return YES;
    [_file waitForBytes:(NSUInteger)end timeout:timeout];
    return _file.available >= end;
}

- (BOOL)parseMoov:(TNBox)moov
{
    const uint8_t *b = _file.bytes;
    uint64_t end = moov.offset + moov.size;
    TNBox trak, mdia, mdhd, minf, stbl, stsd, mvex, trex;
    if (!TNFindChild(b, moov.offset + moov.header, end, TNFourCC('t','r','a','k'), &trak)) return NO;
    if (!TNFindChild(b, trak.offset + trak.header, trak.offset + trak.size, TNFourCC('m','d','i','a'), &mdia)) return NO;
    if (TNFindChild(b, mdia.offset + mdia.header, mdia.offset + mdia.size, TNFourCC('m','d','h','d'), &mdhd)) {
        const uint8_t *p = b + mdhd.offset + mdhd.header;
        _timescale = p[0] == 1 ? TNBE32(p + 4 + 16) : TNBE32(p + 4 + 8);
    }
    if (!TNFindChild(b, mdia.offset + mdia.header, mdia.offset + mdia.size, TNFourCC('m','i','n','f'), &minf)) return NO;
    if (!TNFindChild(b, minf.offset + minf.header, minf.offset + minf.size, TNFourCC('s','t','b','l'), &stbl)) return NO;
    if (!TNFindChild(b, stbl.offset + stbl.header, stbl.offset + stbl.size, TNFourCC('s','t','s','d'), &stsd)) return NO;
    // stsd: version/flags, entry count, then the sample entry ("mp4a")
    uint64_t entryPos = stsd.offset + stsd.header + 8;
    TNBox entry;
    if (!TNReadBox(b, entryPos, stsd.offset + stsd.size, &entry) || entry.type != TNFourCC('m','p','4','a')) {
        TNLog(@"aac: the track is no mp4a");
        return NO;
    }
    const uint8_t *e = b + entry.offset + entry.header;
    // SampleEntry (6 reserved, 2 data reference) + AudioSampleEntry (8 reserved, channels, sample size, 4, rate 16.16)
    uint16_t version = TNBE16(e + 8);
    self.channels = TNBE16(e + 16);
    self.sampleRate = (int)(TNBE32(e + 24) >> 16);
    uint64_t childStart = entry.offset + entry.header + 28 + (version == 1 ? 16 : version == 2 ? 36 : 0);
    TNBox esds;
    if (!TNFindChild(b, childStart, entry.offset + entry.size, TNFourCC('e','s','d','s'), &esds)) { TNLog(@"aac: no esds"); return NO; }
    const uint8_t *d = b + esds.offset + esds.header + 4;
    const uint8_t *dEnd = b + esds.offset + esds.size;
    _cookie = [NSData dataWithBytes:d length:(NSUInteger)(dEnd - d)];
    // ES_Descriptor > DecoderConfigDescriptor (bitrate) > DecoderSpecificInfo (AudioSpecificConfig: the real rate)
    if (d < dEnd && *d == 0x03) {
        uint32_t len = 0;
        NSUInteger n = TNDescriptorLength(d + 1, dEnd, &len);
        const uint8_t *p = d + 1 + n;
        if (n && p + 3 <= dEnd) {
            uint8_t flags = p[2];
            p += 3;
            if (flags & 0x80) p += 2;
            if ((flags & 0x40) && p < dEnd) p += 1 + p[0];
            if (flags & 0x20) p += 2;
            if (p < dEnd && *p == 0x04) {
                n = TNDescriptorLength(p + 1, dEnd, &len);
                const uint8_t *c = p + 1 + n;
                if (n && c + 13 <= dEnd) {
                    self.bitrate = (NSInteger)TNBE32(c + 9);
                    const uint8_t *s = c + 13;
                    if (s < dEnd && *s == 0x05) {
                        n = TNDescriptorLength(s + 1, dEnd, &len);
                        const uint8_t *asc = s + 1 + n;
                        if (n && asc + 2 <= dEnd) {
                            static const int rates[] = { 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };
                            int objectType = asc[0] >> 3;
                            int rateIndex = ((asc[0] & 7) << 1) | (asc[1] >> 7);
                            int channelConfig = (asc[1] >> 3) & 0xf;
                            if (rateIndex < 13) self.sampleRate = rates[rateIndex];
                            if (channelConfig >= 1 && channelConfig <= 2) self.channels = channelConfig;
                            if (objectType != 2) TNLog(@"aac: object type %d (only AAC-LC is meant to play)", objectType);
                        }
                    }
                }
            }
        }
    }
    if (self.channels < 1 || self.channels > 2) self.channels = 2;
    if (self.sampleRate <= 0) self.sampleRate = 44100;
    if (!_timescale) _timescale = (uint32_t)self.sampleRate;
    if (TNFindChild(b, moov.offset + moov.header, end, TNFourCC('m','v','e','x'), &mvex) &&
        TNFindChild(b, mvex.offset + mvex.header, mvex.offset + mvex.size, TNFourCC('t','r','e','x'), &trex)) {
        const uint8_t *p = b + trex.offset + trex.header;
        _defaultDuration = TNBE32(p + 12);
        _defaultSize = TNBE32(p + 16);
    }
    return YES;
}

- (void)parseSidx:(TNBox)sidx
{
    const uint8_t *p = _file.bytes + sidx.offset + sidx.header;
    const uint8_t *end = _file.bytes + sidx.offset + sidx.size;
    uint8_t version = p[0];
    uint32_t timescale = TNBE32(p + 8);
    uint64_t earliest, firstOffset;
    p += 12;
    if (version == 0) { earliest = TNBE32(p); firstOffset = TNBE32(p + 4); p += 8; }
    else { earliest = TNBE64(p); firstOffset = TNBE64(p + 8); p += 16; }
    uint16_t count = TNBE16(p + 2);
    p += 4;
    if (!timescale) return;
    uint64_t offset = sidx.offset + sidx.size + firstOffset;
    uint64_t time = earliest;
    [_index removeAllObjects];
    for (uint16_t i = 0; i < count && p + 12 <= end; i++, p += 12) {
        uint32_t size = TNBE32(p) & 0x7fffffff;
        uint32_t duration = TNBE32(p + 4);
        uint64_t frame = time * (uint64_t)self.sampleRate / timescale;
        [_index addObject:@[ @(offset), @(frame) ]];
        offset += size;
        time += duration;
    }
}

- (BOOL)makeConverter:(NSError **)error
{
    AudioStreamBasicDescription in;
    memset(&in, 0, sizeof(in));
    in.mSampleRate = self.sampleRate;
    in.mFormatID = kAudioFormatMPEG4AAC;
    in.mChannelsPerFrame = (UInt32)self.channels;
    in.mFramesPerPacket = 1024;
    AudioStreamBasicDescription out;
    memset(&out, 0, sizeof(out));
    out.mSampleRate = self.sampleRate;
    out.mFormatID = kAudioFormatLinearPCM;
    out.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    out.mChannelsPerFrame = (UInt32)self.channels;
    out.mBitsPerChannel = 16;
    out.mBytesPerFrame = 2 * (UInt32)self.channels;
    out.mFramesPerPacket = 1;
    out.mBytesPerPacket = out.mBytesPerFrame;
    OSStatus status = AudioConverterNew(&in, &out, &_converter);
    if (status != noErr || !_converter) {
        _converter = NULL;
        if (error) *error = TNMakeError(TNErrorPlayback, [NSString stringWithFormat:L(@"The sound could not be decoded (AAC error %d)."), (int)status]);
        return NO;
    }
    if (_cookie.length) {
        status = AudioConverterSetProperty(_converter, kAudioConverterDecompressionMagicCookie, (UInt32)_cookie.length, _cookie.bytes);
        if (status != noErr) TNLog(@"aac: the converter refused the codec setup (%d), going on without it", (int)status);
    }
    return YES;
}

- (BOOL)open:(NSError **)error
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    uint64_t pos = 0;
    BOOL haveMoov = NO;
    while ([deadline timeIntervalSinceNow] > 0) {
        if (![self need:pos + 16 timeout:2]) {
            if (_file.finished && _file.available < pos + 16) break;
            continue;
        }
        TNBox box;
        if (!TNReadBox(_file.bytes, pos, _file.available, &box)) break;
        if (box.type == TNFourCC('m','o','o','f') || box.type == TNFourCC('m','d','a','t')) break;   // the fragments begin
        if (box.type == TNFourCC('m','o','o','v') || box.type == TNFourCC('s','i','d','x')) {
            if (![self need:box.offset + box.size timeout:10]) {
                if (_file.finished) break;
                continue;
            }
            if (box.type == TNFourCC('m','o','o','v')) haveMoov = [self parseMoov:box];
            else [self parseSidx:box];
        }
        pos = box.offset + box.size;
    }
    if (!haveMoov) {
        if (error) *error = _file.error ?: TNMakeError(TNErrorPlayback, L(@"The song's file is not one this player knows."));
        if (_file.error && error) *error = _file.error;
        return NO;
    }
    _dataStart = pos;
    _scanPos = pos;
    if (![self makeConverter:error]) return NO;
    TNLog(@"aac: %d Hz, %d channel(s), %ld kbit/s, %lu index entries", self.sampleRate, self.channels, (long)(self.bitrate / 1000), (unsigned long)_index.count);
    return YES;
}

#pragma mark - Fragments

- (void)reserveSamples:(NSUInteger)count
{
    if (count <= _sampleCapacity) return;
    _sampleCapacity = count + 64;
    _offsets = realloc(_offsets, _sampleCapacity * sizeof(uint64_t));
    _sizes = realloc(_sizes, _sampleCapacity * sizeof(uint32_t));
}

// The samples of a moof (its data lies in the mdat after it)
- (void)parseMoof:(TNBox)moof
{
    const uint8_t *b = _file.bytes;
    uint64_t end = moof.offset + moof.size;
    _sampleCount = 0;
    _sampleIndex = 0;
    TNBox traf;
    if (!TNFindChild(b, moof.offset + moof.header, end, TNFourCC('t','r','a','f'), &traf)) return;
    uint64_t trafEnd = traf.offset + traf.size;
    uint64_t base = moof.offset;
    uint32_t defaultDuration = _defaultDuration, defaultSize = _defaultSize;
    TNBox tfhd, tfdt;
    if (TNFindChild(b, traf.offset + traf.header, trafEnd, TNFourCC('t','f','h','d'), &tfhd)) {
        const uint8_t *p = b + tfhd.offset + tfhd.header;
        uint32_t flags = TNBE32(p) & 0xffffff;
        p += 8;   // version/flags, track id
        if (flags & 0x01) { base = TNBE64(p); p += 8; }
        if (flags & 0x02) p += 4;
        if (flags & 0x08) { defaultDuration = TNBE32(p); p += 4; }
        if (flags & 0x10) { defaultSize = TNBE32(p); p += 4; }
    }
    if (_resyncFrame && TNFindChild(b, traf.offset + traf.header, trafEnd, TNFourCC('t','f','d','t'), &tfdt)) {
        const uint8_t *p = b + tfdt.offset + tfdt.header;
        uint64_t t = p[0] == 1 ? TNBE64(p + 4) : TNBE32(p + 4);
        self.frame = t * (uint64_t)self.sampleRate / (_timescale ?: (uint32_t)self.sampleRate);
        _resyncFrame = NO;
    }
    // every trun of the fragment, one after the other
    uint64_t p0 = traf.offset + traf.header;
    uint64_t nextData = end + 8;   // (no offset given: the data starts in the mdat right behind)
    TNBox trun;
    while (p0 + 8 <= trafEnd && TNReadBox(b, p0, trafEnd, &trun)) {
        p0 = trun.offset + trun.size;
        if (trun.type != TNFourCC('t','r','u','n')) continue;
        const uint8_t *p = b + trun.offset + trun.header;
        const uint8_t *pEnd = b + trun.offset + trun.size;
        uint32_t flags = TNBE32(p) & 0xffffff;
        uint32_t count = TNBE32(p + 4);
        p += 8;
        uint64_t data = nextData;
        if (flags & 0x01) { data = base + (uint64_t)(int64_t)(int32_t)TNBE32(p); p += 4; }
        if (flags & 0x04) p += 4;
        NSUInteger perSample = ((flags & 0x100) ? 4 : 0) + ((flags & 0x200) ? 4 : 0) + ((flags & 0x400) ? 4 : 0) + ((flags & 0x800) ? 4 : 0);
        if (count > 100000 || p + (uint64_t)perSample * count > pEnd) break;
        [self reserveSamples:_sampleCount + count];
        for (uint32_t i = 0; i < count; i++) {
            uint32_t size = defaultSize;
            if (flags & 0x100) p += 4;   // (the duration: 1024 for AAC, the position comes from the decoder)
            if (flags & 0x200) { size = TNBE32(p); p += 4; }
            if (flags & 0x400) p += 4;
            if (flags & 0x800) p += 4;
            _offsets[_sampleCount] = data;
            _sizes[_sampleCount] = size;
            _sampleCount++;
            data += size;
        }
        nextData = data;
    }
    (void)defaultDuration;
}

// 1: a fragment is ready; 0: its bytes are not here yet; -1: the end (or a broken file)
- (int)loadNextFragment
{
    for (int guard = 0; guard < 10000; guard++) {
        NSUInteger length = _file.length;
        if (length && _scanPos + 8 > length) return -1;
        uint64_t headerEnd = _scanPos + 16;
        if (length && headerEnd > length) headerEnd = length;
        if (![self need:headerEnd timeout:0.5]) return _file.finished ? -1 : 0;
        TNBox box;
        if (!TNReadBox(_file.bytes, _scanPos, _file.available, &box)) return _file.finished ? -1 : 0;
        if (box.type == TNFourCC('m','o','o','f')) {
            if (![self need:box.offset + box.size timeout:0.5]) return _file.finished ? -1 : 0;
            [self parseMoof:box];
            _scanPos = box.offset + box.size;
            if (_sampleCount) return 1;
            continue;
        }
        _scanPos = box.offset + box.size;   // (mdat, free, emsg...: only their headers matter here)
    }
    return -1;
}

#pragma mark - Decoding

static inline int16_t TNScale(int16_t v, float gain)
{
    float f = (float)v * gain;
    if (f > 32767.f) return 32767;
    if (f < -32768.f) return -32768;
    return (int16_t)f;
}

// One packet into _pcm; the number of frames that came out (AAC decoders may hold the first one back), -1 broken
- (NSInteger)decodePacket:(const uint8_t *)data size:(uint32_t)size
{
    TNPacketFeed feed;
    memset(&feed, 0, sizeof(feed));
    feed.data = data;
    feed.size = size;
    feed.channels = (UInt32)self.channels;
    AudioBufferList out;
    out.mNumberBuffers = 1;
    out.mBuffers[0].mNumberChannels = (UInt32)self.channels;
    out.mBuffers[0].mDataByteSize = TNMaxPacketFrames * 2 * (UInt32)self.channels;
    out.mBuffers[0].mData = _pcm;
    UInt32 frames = TNMaxPacketFrames;
    OSStatus status = AudioConverterFillComplexBuffer(_converter, TNFeedPacket, &feed, &frames, &out, NULL);
    if (status != noErr && status != TNNoMoreInput) {
        TNLog(@"aac: decoding failed (%d)", (int)status);
        return frames > 0 ? (NSInteger)frames : -1;
    }
    return (NSInteger)frames;
}

- (NSInteger)readFrames:(int16_t *)out max:(NSUInteger)maxFrames gain:(float)gain
{
    if (!_converter) return -1;
    self.starved = NO;
    NSUInteger produced = 0;
    int failures = 0;
    while (produced < maxFrames) {
        if (_pcmIndex < _pcmCount) {
            NSUInteger n = MIN(_pcmCount - _pcmIndex, maxFrames - produced);
            int16_t *o = out + produced * 2;
            if (self.channels == 1) {
                const int16_t *src = _pcm + _pcmIndex;
                for (NSUInteger i = 0; i < n; i++) o[2 * i] = o[2 * i + 1] = gain == 1.f ? src[i] : TNScale(src[i], gain);
            } else {
                const int16_t *src = _pcm + _pcmIndex * 2;
                if (gain == 1.f) memcpy(o, src, n * 4);
                else for (NSUInteger i = 0; i < n * 2; i++) o[i] = TNScale(src[i], gain);
            }
            _pcmIndex += n;
            produced += n;
            self.frame += n;
            continue;
        }
        if (_sampleIndex >= _sampleCount) {
            int r = [self loadNextFragment];
            if (r < 0) {
                if (_file.error && _file.available < _file.length) return produced ? (NSInteger)produced : -1;
                self.atEnd = YES;
                break;
            }
            if (r == 0) { self.starved = YES; break; }
            continue;
        }
        uint64_t offset = _offsets[_sampleIndex];
        uint32_t size = _sizes[_sampleIndex];
        if (!size || (_file.length && offset + size > _file.length)) { _sampleIndex++; continue; }
        if (offset + size > _file.available) {
            if (_file.finished) {
                if (_file.error) return produced ? (NSInteger)produced : -1;
                self.atEnd = YES;
                break;
            }
            if (![self need:offset + size timeout:0.5]) { self.starved = YES; break; }
            continue;
        }
        NSInteger got = [self decodePacket:_file.bytes + offset size:size];
        _sampleIndex++;
        if (got < 0) {
            // (one bad packet is skipped; many in a row mean the stream is broken)
            if (++failures > 8) return produced ? (NSInteger)produced : -1;
            continue;
        }
        _pcmCount = (NSUInteger)got;
        _pcmIndex = 0;
    }
    return (NSInteger)produced;
}

- (BOOL)seekToFrame:(uint64_t)target
{
    if (!_converter) return NO;
    // the fragment that holds the spot: from the index when there is one, else the first
    uint64_t offset = _dataStart, startFrame = 0;
    for (NSArray *entry in _index) {
        uint64_t f = [entry[1] unsignedLongLongValue];
        if (f > target) break;
        offset = [entry[0] unsignedLongLongValue];
        startFrame = f;
    }
    if (![self need:MIN(offset + 65536, (uint64_t)(_file.length ?: offset + 65536)) timeout:20] && _file.available <= offset) return NO;
    _scanPos = offset;
    _sampleCount = _sampleIndex = 0;
    _pcmCount = _pcmIndex = 0;
    AudioConverterReset(_converter);
    self.atEnd = NO;
    self.frame = startFrame;
    _resyncFrame = YES;
    // decode up to the spot and drop it, so the position is exact
    if (target > self.frame && target - self.frame < (uint64_t)(60 * self.sampleRate)) {
        int16_t scratch[2048 * 2];
        int idle = 0;
        while (self.frame < target && idle < 200) {
            NSUInteger want = (NSUInteger)MIN((uint64_t)2048, target - self.frame);
            NSInteger got = [self readFrames:scratch max:want gain:0];
            if (got < 0 || self.atEnd) break;
            if (got == 0) idle++;
        }
    }
    return YES;
}

@end
