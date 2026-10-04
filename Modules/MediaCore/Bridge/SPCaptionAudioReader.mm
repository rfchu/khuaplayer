// Independent audio decoding and resampling for caption generation.
#import "SPCaptionAudioReader.h"
#include "SPRuntimeGates.hpp"

#include <atomic>
#include <cmath>
#include <mutex>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

static const int kCapSampleRate = 16000;

@interface SPCaptionAudioReader ()
- (int)ioRead:(uint8_t *)buf size:(int)size;
- (int64_t)ioSeek:(int64_t)offset whence:(int)whence;
- (BOOL)interrupted;
- (nullable NSData *)readLockedFromSeconds:(double)start durationSeconds:(double)duration;
@end

@implementation SPCaptionAudioReader {
    NSString *_path;
    int _wantStream;
    std::atomic<bool> _abort;
    std::mutex _mtx; // Serialize reads defensively; callers use one dedicated worker.
    AVFormatContext *_ctx;
    AVCodecContext *_dec;
    SwrContext *_swr;
    AVFrame *_frame;
    AVPacket *_pkt;
    int _stream;
    AVRational _tb;
    int64_t _originUs;      // Signed origin used to convert container timestamps to the playback timeline.
    bool _openFailed;
    bool _ioPolicyApplied;
    int _swrInFmt, _swrInRate;
    AVChannelLayout _swrInLayout;
    AVChannelLayout _outLayout;
    uint8_t *_convBuf;
    int _convCap;
    // Independent sequential AVIO reads with admission checks before each block:
    // up to 256 KiB locally or 1 MiB on a network volume.
    int _fd;
    int64_t _fileSize;
    int64_t _ioPos;     // Logical AVIO position.
    int64_t _fdPos;     // Physical descriptor position; seek when it differs from the logical position.
    bool _remote;
    std::atomic<int64_t> _bytesRead;
    BOOL (^_pauseBlock)(void); // True pauses at block boundaries without abandoning progress.
    NSError *_openError;
}

#define SPLOG(fmt, ...) NSLog(@"[c%u]" fmt, self->_spLogId, ##__VA_ARGS__)

// Match the demuxer timeline origin: signed container start, earliest declared
// stream start, or zero when no timestamp is available.
static int64_t spCapTimelineOrigin(AVFormatContext *c) {
    if (c->start_time != AV_NOPTS_VALUE) return c->start_time;
    int64_t mn = INT64_MAX;
    for (unsigned i = 0; i < c->nb_streams; ++i) {
        AVStream *s = c->streams[i];
        if (s->start_time == AV_NOPTS_VALUE) continue;
        int64_t us = av_rescale_q(s->start_time, s->time_base, AV_TIME_BASE_Q);
        if (us < mn) mn = us;
    }
    return mn != INT64_MAX ? mn : 0;
}

static int spCapInterruptCb(void *opaque) {
    SPCaptionAudioReader *r = (__bridge SPCaptionAudioReader *)opaque;
    return [r interrupted] ? 1 : 0;
}

// AVIO callbacks check admission before every block and remain abortable
// while waiting in 100 ms intervals.
static int spCapIORead(void *opaque, uint8_t *buf, int size) {
    SPCaptionAudioReader *r = (__bridge SPCaptionAudioReader *)opaque;
    return [r ioRead:buf size:size];
}
static int64_t spCapIOSeek(void *opaque, int64_t offset, int whence) {
    SPCaptionAudioReader *r = (__bridge SPCaptionAudioReader *)opaque;
    return [r ioSeek:offset whence:whence];
}

- (instancetype)initWithPath:(NSString *)path audioStreamIndex:(int)streamIndex {
    self = [super init];
    if (self) {
        _path = [path copy];
        _wantStream = streamIndex;
        _abort.store(false);
        _fd = -1; _fileSize = 0; _ioPos = 0; _fdPos = 0; _remote = false; _bytesRead.store(0);
        _pauseBlock = nil;
        _ctx = nullptr; _dec = nullptr; _swr = nullptr; _frame = nullptr; _pkt = nullptr;
        _stream = -1;
        _tb = {1, 1};
        _originUs = 0;
        _timelineOriginUs = INT64_MIN; // Unset: derive the timeline origin.
        _openFailed = false;
        _ioPolicyApplied = false;
        _swrInFmt = AV_SAMPLE_FMT_NONE; _swrInRate = 0;
        _swrInLayout = {}; _outLayout = {};
        _convBuf = nullptr; _convCap = 0;
        av_channel_layout_default(&_outLayout, 1);
    }
    return self;
}

- (void)dealloc {
    [self teardown];
    av_channel_layout_uninit(&_outLayout);
}

- (int)sampleRate { return kCapSampleRate; }
- (BOOL)remoteVolume { return _remote; }
- (int64_t)fileSize { return _fileSize; }
- (int64_t)bytesRead { return _bytesRead.load(); }

- (BOOL)open {
    return [self openWithShouldPause:nil];
}

- (BOOL)openWithShouldPause:(BOOL (^)(void))shouldPause {
    std::lock_guard<std::mutex> lk(_mtx);
    _lastError = nil;
    _pauseBlock = shouldPause;
    BOOL opened = ![self interrupted] && [self ensureOpen];
    _pauseBlock = nil;
    return opened;
}

- (void)recordError:(int)code {
    if (_abort.load()) return;
    char detail[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(code, detail, sizeof(detail));
    _lastError = [NSError errorWithDomain:@"SPCaptionAudioReader" code:code
                                userInfo:@{NSLocalizedDescriptionKey: @(detail)}];
}

- (void)recordOpenError:(int)code {
    [self recordError:code];
    if (!_abort.load()) { _openFailed = true; _openError = _lastError; }
}

// Pause sequential work in place. Open, probing and custom read/seek callbacks
// explicitly pass this gate rather than relying solely on protocol interrupts.
- (BOOL)interrupted {
    while (!_abort.load() && _pauseBlock && _pauseBlock()) usleep(100 * 1000);
    return _abort.load();
}

- (int)ioRead:(uint8_t *)buf size:(int)size {
    if ([self interrupted]) return AVERROR_EXIT;
    if (_fd < 0) return AVERROR(EIO);
    size = MIN(size, _remote ? (1 << 20) : (256 << 10));
    if (_fdPos != _ioPos) {
        if (lseek(_fd, _ioPos, SEEK_SET) < 0) return AVERROR(errno);
        _fdPos = _ioPos;
    }
    ssize_t n;
    do { n = read(_fd, buf, (size_t)size); } while (n < 0 && errno == EINTR && ![self interrupted]);
    if (n < 0) return AVERROR(errno);
    // A file shortened/disconnected after open is not a clean end of its original contents.
    if (n == 0) return _ioPos < _fileSize ? AVERROR(EIO) : AVERROR_EOF;
    _ioPos += n;
    _fdPos += n;
    _bytesRead.fetch_add(n, std::memory_order_relaxed);
    return (int)n;
}

- (int64_t)ioSeek:(int64_t)offset whence:(int)whence {
    if ([self interrupted]) return AVERROR_EXIT;
    if (whence == AVSEEK_SIZE) return _fileSize;
    int64_t base = 0;
    switch (whence & ~AVSEEK_FORCE) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = _ioPos; break;
        case SEEK_END: base = _fileSize; break;
        default: return AVERROR(EINVAL);
    }
    if ((offset > 0 && base > INT64_MAX - offset) || (offset < 0 && offset < -base)) return AVERROR(EINVAL);
    int64_t p = base + offset;
    _ioPos = p;
    return p;
}

- (void)abort {
    _abort.store(true);
}

- (void)teardown {
    if (_ctx) {
        if (_ctx->pb && (_ctx->flags & AVFMT_FLAG_CUSTOM_IO)) {
            // CUSTOM_IO retains ownership of its AVIO buffer and context.
            AVIOContext *pb = _ctx->pb;
            _ctx->pb = nullptr;
            if (pb->buffer) av_freep(&pb->buffer);
            avio_context_free(&pb);
        }
    }
    if (_fd >= 0) { ::close(_fd); _fd = -1; }
    if (_swr) swr_free(&_swr);
    av_channel_layout_uninit(&_swrInLayout);
    _swrInFmt = AV_SAMPLE_FMT_NONE; _swrInRate = 0;
    if (_convBuf) { av_free(_convBuf); _convBuf = nullptr; _convCap = 0; }
    if (_frame) av_frame_free(&_frame);
    if (_pkt) av_packet_free(&_pkt);
    if (_dec) avcodec_free_context(&_dec);
    if (_ctx) avformat_close_input(&_ctx);
    _stream = -1;
}

// Lazy open on the caller's dedicated background thread.
- (BOOL)ensureOpen {
    if ([self interrupted]) return NO;
    if (_ctx && _dec) return YES;
    if (_openFailed) { _lastError = _openError; return NO; }
    if (!_ioPolicyApplied) {
        // Throttle background disk I/O so foreground playback can take precedence.
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE);
        _ioPolicyApplied = true;
    }

    BOOL isNetwork = [_path hasPrefix:@"http://"] || [_path hasPrefix:@"https://"] ||
                     [_path hasPrefix:@"rtmp://"] || [_path hasPrefix:@"rtsp://"];

    int fd = -1;
    AVFormatContext *c = nullptr;
    AVIOContext *pb = nullptr;

    if (isNetwork) {
        _remote = true;
        _fileSize = 0;
        _fd = -1;
        _ioPos = 0;
        _fdPos = 0;
        c = avformat_alloc_context();
        if (!c) { [self recordOpenError:AVERROR(ENOMEM)]; return NO; }
        c->interrupt_callback = { spCapInterruptCb, (__bridge void *)self };
        AVDictionary *opts = nullptr;
        av_dict_set(&opts, "timeout", "10000000", 0);
        av_dict_set(&opts, "rw_timeout", "10000000", 0);
        av_dict_set(&opts, "reconnect", "1", 0);
        av_dict_set(&opts, "reconnect_streamed", "1", 0);
        av_dict_set(&opts, "reconnect_delay_max", "5", 0);
        av_dict_set(&opts, "user_agent", "KhuaPlayer/0.7.0", 0);
        av_dict_set(&opts, "scan_all_pmts", "0", 0);
        int ret = avformat_open_input(&c, _path.UTF8String, nullptr, &opts);
        av_dict_free(&opts);
        if (ret < 0) {
            [self recordOpenError:ret];
            if (spDebug()) SPLOG(@"[Captions] 网络音频读取器 open 失败 ret=%d", ret);
            return NO;
        }
    } else {
        // Use an independent descriptor and custom AVIO with playback-compatible block sizing.
        fd = ::open(_path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
        if (fd < 0) { [self recordOpenError:AVERROR(errno)]; return NO; }
        struct stat sb {};
        if ([self interrupted]) { ::close(fd); return NO; }
        if (fstat(fd, &sb) != 0) { int e = errno; ::close(fd); [self recordOpenError:AVERROR(e)]; return NO; }
        _fileSize = (int64_t)sb.st_size;
        (void)fcntl(fd, F_RDAHEAD, 1);
        struct statfs sfs {};
        if ([self interrupted]) { ::close(fd); return NO; }
        if (fstatfs(fd, &sfs) == 0) {
            const char *t = sfs.f_fstypename;
            _remote = strcmp(t, "smbfs") == 0 || strcmp(t, "afpfs") == 0 ||
                      strcmp(t, "nfs") == 0 || strcmp(t, "webdav") == 0;
        }
        _fd = fd;
        _ioPos = 0;
        _fdPos = 0;
        const int granule = _remote ? (1 << 20) : (256 << 10);
        uint8_t *iobuf = (uint8_t *)av_malloc((size_t)granule);
        pb = iobuf ? avio_alloc_context(iobuf, granule, 0, (__bridge void *)self,
                                                     spCapIORead, nullptr, spCapIOSeek) : nullptr;
        if (!pb) { if (iobuf) av_free(iobuf); ::close(fd); _fd = -1; [self recordOpenError:AVERROR(ENOMEM)]; return NO; }
        c = avformat_alloc_context();
        if (!c) {
            av_freep(&pb->buffer); avio_context_free(&pb);
            ::close(fd); _fd = -1; [self recordOpenError:AVERROR(ENOMEM)]; return NO;
        }
        c->pb = pb;
        c->flags |= AVFMT_FLAG_CUSTOM_IO;
        c->interrupt_callback = { spCapInterruptCb, (__bridge void *)self };
        AVDictionary *opts = nullptr;
        av_dict_set(&opts, "scan_all_pmts", "0", 0);
        int ret = avformat_open_input(&c, _path.fileSystemRepresentation, nullptr, &opts);
        av_dict_free(&opts);
        if (ret < 0) {
            // A failed open frees the format context, but custom AVIO remains caller-owned.
            av_freep(&pb->buffer); avio_context_free(&pb);
            ::close(fd); _fd = -1;
            [self recordOpenError:ret];
            if (spDebug()) SPLOG(@"[Captions] 音频读取器 open 失败 ret=%d", ret);
            return NO;
        }
    }
    // TS/PS audio parameters may require bounded stream probing.
    c->max_analyze_duration = 2 * AV_TIME_BASE;
    c->probesize = 4 * 1024 * 1024;
    // Subsequent failures must release the format context, custom AVIO and descriptor.
    auto fail = [&](AVFormatContext *fc) {
        if (fc->flags & AVFMT_FLAG_CUSTOM_IO) {
            AVIOContext *fpb = fc->pb; fc->pb = nullptr;
            avformat_close_input(&fc);
            if (fpb) { av_freep(&fpb->buffer); avio_context_free(&fpb); }
        } else {
            avformat_close_input(&fc);
        }
        if (_fd >= 0) { ::close(_fd); _fd = -1; }
    };
    int infoRet = [self interrupted] ? AVERROR_EXIT : avformat_find_stream_info(c, nullptr);
    int ioError = c->pb ? c->pb->error : 0;
    if ((infoRet < 0 && infoRet != AVERROR_EOF && infoRet != AVERROR_INVALIDDATA) || (ioError < 0 && ioError != AVERROR_EOF)) {
        fail(c);
        [self recordOpenError:ioError < 0 && ioError != AVERROR_EOF ? ioError : infoRet];
        return NO;
    }
    int s = -1;
    if (_wantStream >= 0 && (unsigned)_wantStream < c->nb_streams &&
        c->streams[_wantStream]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
        s = _wantStream;
    } else {
        s = av_find_best_stream(c, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    }
    if (s < 0) {
        fail(c);
        [self recordOpenError:s];
        if (spDebug()) SPLOG(@"[Captions] 无音频流");
        return NO;
    }
    AVStream *st = c->streams[s];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    AVCodecContext *dec = codec ? avcodec_alloc_context3(codec) : nullptr;
    int paramRet = dec ? avcodec_parameters_to_context(dec, st->codecpar) : AVERROR(ENOMEM);
    if (paramRet < 0) {
        if (dec) avcodec_free_context(&dec);
        fail(c);
        [self recordOpenError:paramRet];
        return NO;
    }
    AVDictionary *dopts = nullptr;
    if (st->codecpar->codec_id == AV_CODEC_ID_AC3 || st->codecpar->codec_id == AV_CODEC_ID_EAC3) {
        av_dict_set(&dopts, "drc_scale", "0", 0);
    }
    int oret = avcodec_open2(dec, codec, &dopts);
    av_dict_free(&dopts);
    if (oret < 0) {
        avcodec_free_context(&dec);
        fail(c);
        [self recordOpenError:oret];
        return NO;
    }
    // Discard unrelated streams before packet construction.
    for (unsigned i = 0; i < c->nb_streams; ++i) {
        if ((int)i != s) c->streams[i]->discard = AVDISCARD_ALL;
    }
    _ctx = c;
    _dec = dec;
    _stream = s;
    _tb = st->time_base;
    _originUs = _timelineOriginUs != INT64_MIN ? _timelineOriginUs : spCapTimelineOrigin(c);
    _frame = av_frame_alloc();
    _pkt = av_packet_alloc();
    if (!_frame || !_pkt) { [self recordOpenError:AVERROR(ENOMEM)]; [self teardown]; return NO; }
    if (spDebug()) {
        SPLOG(@"[Captions] 音频读取器就绪：流#%d %s %dch %dHz origin=%.3fs",
              s, codec->name, st->codecpar->ch_layout.nb_channels,
              st->codecpar->sample_rate, _originUs / 1e6);
    }
    return YES;
}

- (int)ensureSwrForFrame:(AVFrame *)f {
    if (_swr && f->format == _swrInFmt && f->sample_rate == _swrInRate &&
        av_channel_layout_compare(&f->ch_layout, &_swrInLayout) == 0) {
        return 0;
    }
    if (_swr) swr_free(&_swr);
    SwrContext *swr = nullptr;
    // Downmix to mono with common-ratio normalization to prevent clipping.
    int ret = swr_alloc_set_opts2(&swr, &_outLayout, AV_SAMPLE_FMT_S16, kCapSampleRate,
                                &f->ch_layout, (AVSampleFormat)f->format, f->sample_rate,
                                0, nullptr);
    if (ret < 0 || !swr) { swr_free(&swr); return ret < 0 ? ret : AVERROR(ENOMEM); }
    av_opt_set_double(swr, "rematrix_maxval", 1.0, 0);
    ret = swr_init(swr);
    if (ret < 0) { swr_free(&swr); return ret; }
    _swr = swr;
    _swrInFmt = f->format;
    _swrInRate = f->sample_rate;
    av_channel_layout_uninit(&_swrInLayout);
    ret = av_channel_layout_copy(&_swrInLayout, &f->ch_layout);
    if (ret < 0) { swr_free(&_swr); return ret; }
    return 0;
}

- (nullable NSData *)readMonoPCMFromSeconds:(double)start durationSeconds:(double)duration {
    return [self readMonoPCMFromSeconds:start durationSeconds:duration shouldPause:nil];
}

- (nullable NSData *)readMonoPCMFromSeconds:(double)start durationSeconds:(double)duration
                                shouldPause:(nullable BOOL (^)(void))shouldPause {
    std::lock_guard<std::mutex> lk(_mtx);
    _lastError = nil;
    if (!std::isfinite(start) || !std::isfinite(duration) || duration <= 0 || start < 0 ||
        duration > INT32_MAX / (double)kCapSampleRate || start > (double)(INT64_MAX / AV_TIME_BASE) - duration) {
        [self recordError:AVERROR(EINVAL)]; return nil;
    }
    _pauseBlock = shouldPause;
    NSData *out = [self ensureOpen] ? [self readLockedFromSeconds:start durationSeconds:duration] : nil;
    _pauseBlock = nil;
    return out;
}

- (nullable NSData *)readLockedFromSeconds:(double)start durationSeconds:(double)duration {
    const int64_t totalSamples = (int64_t)llround(duration * kCapSampleRate);
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)totalSamples * sizeof(int16_t)];
    int16_t *dst = (int16_t *)out.mutableBytes;

    // Seek one second early to warm decoding and resampling before the requested interval.
    const double seekSec = MAX(0.0, start - 1.0);
    const int64_t seekTs = av_rescale_q((int64_t)(seekSec * AV_TIME_BASE) + _originUs,
                                        AV_TIME_BASE_Q, _tb);
    if (av_seek_frame(_ctx, _stream, seekTs, AVSEEK_FLAG_BACKWARD) < 0) {
        // Fall back to a timestamp seek when the selected stream lacks a usable index.
        int ret = avformat_seek_file(_ctx, -1, INT64_MIN,
                               (int64_t)(seekSec * AV_TIME_BASE) + _originUs, INT64_MAX, 0);
        if (ret < 0) {
            [self recordError:ret];
            return nil;
        }
    }
    avcodec_flush_buffers(_dec);
    if (_swr) {
        // Discard samples retained by the previous resampling interval.
        swr_free(&_swr);
        _swrInFmt = AV_SAMPLE_FMT_NONE;
    }
    const double endSec = start + duration;
    // Container timestamps can be coarser than one audio frame. A delta within
    // one tick is quantization, not evidence of lost media. Explicit damage
    // still resets immediately; gaps larger than this precision reset below.
    const double timestampTolerance = MAX(0.002, av_q2d(_tb) + 0.000001);
    bool eof = false, pastEnd = false, wroteAny = false, damagedWindow = false;
    bool timelineUnknown = false;
    int64_t maxWritten = 0, damagedThrough = 0;
    double nextPos = -1;      // next resampled output position (including its delay)
    double nextFramePos = -1; // input timeline also advances across discarded damage
    double unanchoredDuration = 0;
    int unanchoredFrames = 0;
    auto resetResampler = [&] {
        if (_swr) swr_free(&_swr);
        _swrInFmt = AV_SAMPLE_FMT_NONE;
        nextPos = -1;
    };
    auto noteDamage = [&](double at, double length) {
        if (!std::isfinite(at) || (at < endSec && (length <= 0 || at + length > start))) {
            damagedWindow = true;
            if (std::isfinite(at) && length > 0) {
                damagedThrough = MAX(damagedThrough, (int64_t)llround(
                    MIN(duration, MAX(0.0, at + length - start)) * kCapSampleRate));
            }
        }
        timelineUnknown = !std::isfinite(at) || length <= 0;
        nextFramePos = timelineUnknown ? -1 : at + length;
        // Buffered samples from before a lost packet must not fill the hole.
        resetResampler();
    };
    auto emit = [&](const int16_t *src, int n, double atSec) {
        int64_t off = (int64_t)llround((atSec - start) * kCapSampleRate);
        if (off >= totalSamples) return;
        int skip = 0;
        if (off < 0) { skip = (int)MIN((int64_t)n, -off); off = 0; }
        int cnt = (int)MIN((int64_t)(n - skip), totalSamples - off);
        if (cnt <= 0) return;
        memcpy(dst + off, src + skip, (size_t)cnt * sizeof(int16_t));
        wroteAny = true;
        maxWritten = MAX(maxWritten, off + cnt);
        nextPos = atSec + (double)n / kCapSampleRate;
    };
    // send_packet(EAGAIN) means the packet was NOT consumed. Drain first, then
    // retry that same packet. Keep a bounded error path for broken decoders.
    auto drain = [&]() -> int {
        int invalidFrames = 0;
        while (true) {
            if ([self interrupted]) return AVERROR_EXIT;
            int rr = avcodec_receive_frame(_dec, _frame);
            if (rr == AVERROR(EAGAIN) || rr == AVERROR_EOF) return 0;
            if (rr == AVERROR_INVALIDDATA) {
                noteDamage(NAN, 0);
                if (++invalidFrames >= 32) return rr;
                continue;
            }
            if (rr < 0) return rr;
            invalidFrames = 0;
            const double frameDuration = _frame->sample_rate > 0
                ? (double)_frame->nb_samples / _frame->sample_rate : 0;
            double pts = nextFramePos;
            int64_t bts = _frame->best_effort_timestamp;
            if (bts != AV_NOPTS_VALUE) {
                pts = (double)(av_rescale_q(bts, _tb, AV_TIME_BASE_Q) - _originUs) / 1e6;
                timelineUnknown = false;
                unanchoredDuration = 0; unanchoredFrames = 0;
            } else if (timelineUnknown) {
                // No duration/PTS for the damaged input: concatenating the next
                // frame would shift speech early. Wait for a timestamp anchor,
                // bounded to one window (and a frame limit for invalid lengths).
                unanchoredDuration += MAX(0.0, frameDuration);
                av_frame_unref(_frame);
                if (unanchoredDuration >= duration || ++unanchoredFrames >= 256) return AVERROR_INVALIDDATA;
                continue;
            } else if (pts < 0) {
                pts = seekSec;
            }
            if (pts > endSec + 0.5) { pastEnd = true; av_frame_unref(_frame); return 0; }
            if ((_frame->flags & AV_FRAME_FLAG_CORRUPT) || _frame->decode_error_flags) {
                noteDamage(pts, frameDuration);
                av_frame_unref(_frame);
                continue;
            }
            // Timestamp discontinuities are holes in the media timeline, not
            // permission to concatenate speech from either side of the damage.
            if (nextFramePos >= 0 && std::abs(pts - nextFramePos) > timestampTolerance) resetResampler();
            nextFramePos = pts + frameDuration;
            int swrRet = [self ensureSwrForFrame:_frame];
            if (swrRet < 0) { av_frame_unref(_frame); return swrRet; }
            int need = (int)av_rescale_rnd(_frame->nb_samples + 1024, kCapSampleRate,
                                           _frame->sample_rate, AV_ROUND_UP);
            if (need > _convCap) {
                if (_convBuf) av_free(_convBuf);
                _convCap = need;
                _convBuf = (uint8_t *)av_malloc((size_t)_convCap * sizeof(int16_t));
                if (!_convBuf) { _convCap = 0; av_frame_unref(_frame); return AVERROR(ENOMEM); }
            }
            double delaySec = (double)swr_get_delay(_swr, kCapSampleRate) / kCapSampleRate;
            const uint8_t **in = (const uint8_t **)_frame->extended_data;
            int n = swr_convert(_swr, &_convBuf, _convCap, in, _frame->nb_samples);
            if (n < 0) { av_frame_unref(_frame); return n; }
            if (n > 0) emit((const int16_t *)_convBuf, n, pts - delaySec);
            av_frame_unref(_frame);
        }
    };
    int demuxErrors = 0;
    while (!eof && !pastEnd) {
        if ([self interrupted]) return nil;
        int r = av_read_frame(_ctx, _pkt);
        int ioError = _ctx->pb ? _ctx->pb->error : 0;
        if (ioError < 0 && ioError != AVERROR_EOF) {
            av_packet_unref(_pkt); [self recordError:ioError]; return nil;
        }
        if (r < 0 && r != AVERROR_EOF) {
            av_packet_unref(_pkt);
            if (r == AVERROR_INVALIDDATA && ++demuxErrors < 256) {
                noteDamage(NAN, 0);
                continue;
            }
            [self recordError:r]; return nil;
        }
        demuxErrors = 0;
        eof = r == AVERROR_EOF;
        double packetAt = NAN, packetDuration = 0;
        if (!eof) {
            if (_pkt->stream_index != _stream) { av_packet_unref(_pkt); continue; }
            int64_t ts = _pkt->pts != AV_NOPTS_VALUE ? _pkt->pts : _pkt->dts;
            if (ts != AV_NOPTS_VALUE) packetAt = (double)(av_rescale_q(ts, _tb, AV_TIME_BASE_Q) - _originUs) / 1e6;
            else if (nextFramePos >= 0) packetAt = nextFramePos;
            if (_pkt->duration > 0) packetDuration = (double)av_rescale_q(_pkt->duration, _tb, AV_TIME_BASE_Q) / 1e6;
            if (_pkt->flags & AV_PKT_FLAG_CORRUPT) {
                if (packetAt > endSec + 0.5) { av_packet_unref(_pkt); break; }
                noteDamage(packetAt, packetDuration);
                av_packet_unref(_pkt);
                continue;
            }
        }
        int sr = avcodec_send_packet(_dec, eof ? nullptr : _pkt);
        if (sr == AVERROR(EAGAIN)) {
            int rr = drain();
            if (rr < 0) { av_packet_unref(_pkt); [self recordError:rr]; return nil; }
            if (pastEnd) { av_packet_unref(_pkt); break; }
            sr = avcodec_send_packet(_dec, eof ? nullptr : _pkt);
        }
        av_packet_unref(_pkt);
        if (sr == AVERROR_INVALIDDATA) {
            noteDamage(packetAt, packetDuration);
        } else if (sr < 0 && !(eof && sr == AVERROR_EOF)) {
            [self recordError:sr]; return nil;
        }
        int rr = drain();
        if (rr < 0) { [self recordError:rr]; return nil; }
    }
    if (_swr) {
        // Drain the resampler tail.
        int n = swr_convert(_swr, &_convBuf, _convCap, nullptr, 0);
        if (n < 0) { [self recordError:n]; return nil; }
        if (n > 0 && nextPos >= 0) emit((const int16_t *)_convBuf, n, nextPos);
    }
    if (_abort.load()) return nil;
    if (timelineUnknown && maxWritten < totalSamples) {
        [self recordError:AVERROR_INVALIDDATA]; return nil;
    }
    if (!wroteAny) {
        // A wholly damaged window is not a valid silent recording or clean EOF.
        if (damagedWindow) { [self recordError:AVERROR_INVALIDDATA]; return nil; }
        return [NSData data];
    }
    int64_t coveredThrough = MAX(maxWritten, damagedThrough);
    if (eof && coveredThrough < totalSamples) {
        out.length = (NSUInteger)coveredThrough * sizeof(int16_t);
    }
    return out;
}

@end
