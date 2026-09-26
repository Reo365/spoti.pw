// The player's cover plays the album's animation, the way the Music app's does: the same clip
// Shared/LockScreenArtwork puts on the lock screen, laid over the cover PlayerArtwork.x has rounded
// and shadowed. The clip is not fetched here -- the mod fetches one at a time and the lock screen's
// has first claim on it, so this plays what is on disk and asks again on the next track when there
// is nothing yet (SGArtworkClip). The sources are the ones the lock screen page puts in order, so the
// one setting there governs both.
//
//     the layer      one AVPlayerLayer on a single AVPlayer, moved onto whichever cover is showing.
//                    The queue behind the player is a cover per cell, so the layer follows the track
//                    rather than living on a view that scrolls away, and exactly one player exists
//     the loop       the item's end, seeking to zero and playing on. No display link of our own: one
//                    capped at 60 Hz would drag the player's 120 Hz transitions down with it
//     the fade       the layer stays transparent until AVPlayerLayer has a frame to show, then fades
//                    in over the still cover Spotify drew underneath it
//
// The clip carries its own sound, which the song is already playing, so the player is muted. One
// AVPlayer exists at a time and is let go when the player closes, when the switch is read off, and
// when a track with no clip is wanted: the cover that was there is left showing rather than a black
// one. The lyrics come over the cover rather than under it, so the layer rides along beneath them.
//
// Every hook installs only while Redesigned UI is on (SGRedesignedUI). Threading: main thread only;
// the clip is fetched, cropped and decoded off it, and every callback comes back onto it.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"
#import "Shared/LockScreenArtwork/SGAppleArtwork.h"
#import "Shared/LockScreenArtwork/SGArtworkFile.h"
#import "Shared/LockScreenArtwork/SGCanvas.h"

// A square cover, which is what the crop is asked for; a clip already that shape is handed over as it is.
static const CGFloat kCoverAspect = 1.0;

@class SGRMotionDisplay;

static AVPlayer *sg_player;
static AVPlayerLayer *sg_layer;
static id sg_endOfItem;         // the AVPlayerItemDidPlayToEndTime observer
static SGRMotionDisplay *sg_display;
static UIView *sg_host;          // the cover the layer is on
static NSString *sg_wanted;      // the track a clip is being looked for
static NSDictionary *sg_metadata;   // the wanted track's metadata, for the Canvas out of it
static SPTPlayerTrack *sg_track;

#pragma mark - what the cover is doing now

// The layer plays only over a cover on screen, and not while the player is between its two states.
static BOOL coverShows(void) {
    if (SGRPlayerIsTransitioning()) return NO;
    return SGRPlayerCoverView() != nil;
}

static void layout(void) {
    if (!sg_layer || !sg_host) return;
    // The paused shrink is a transform on the cover, so the layer under it needs nothing of its own.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    sg_layer.frame = sg_host.bounds;
    [CATransaction commit];
}

static void release(void) {
    [sg_player pause];
    if (sg_endOfItem) {
        [NSNotificationCenter.defaultCenter removeObserver:sg_endOfItem];
        sg_endOfItem = nil;
    }
    sg_display = nil;   // its dealloc stops watching the layer
    [sg_layer removeFromSuperlayer];
    sg_layer = nil;
    sg_player = nil;
    sg_host = nil;
}

// Playing, paused or hidden, whatever the cover and the switch say at this moment.
static void sync(void) {
    if (!SGFlag(SGRKeyCoverMotion, NO) || !sg_player) {
        [sg_player pause];
        return;
    }
    UIView *cover = SGRPlayerCoverView();
    if (cover != sg_host) {
        [sg_layer removeFromSuperlayer];
        sg_host = cover;
        if (cover) {
            [cover.layer addSublayer:sg_layer];
            SGRObserveLayout(cover, ^(UIView *view) {
                if (view == sg_host) layout();
            });
        }
    }
    BOOL shows = cover != nil && coverShows();
    sg_layer.hidden = !shows;
    if (shows) {
        layout();
        [sg_player play];
    } else {
        [sg_player pause];
    }
}

#pragma mark - the first frame

@interface SGRMotionDisplay : NSObject
@end

@implementation SGRMotionDisplay {
    AVPlayerLayer *_layer;
}

+ (instancetype)watching:(AVPlayerLayer *)layer {
    SGRMotionDisplay *watcher = [SGRMotionDisplay new];
    watcher->_layer = layer;
    [layer addObserver:watcher forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionNew context:NULL];
    return watcher;
}

- (void)dealloc {
    [_layer removeObserver:self forKeyPath:@"readyForDisplay"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"readyForDisplay"] || ![change[NSKeyValueChangeNewKey] boolValue]) return;
    // The layer is transparent until now, so the still cover has been showing through it; the fade is
    // the swap from one to the other and not a fade in from black.
    SGRAnimate(SGRMotionFade, ^{
        sg_layer.opacity = 1;
    }, nil);
    sg_display = nil;   // watched for this one frame only; its dealloc stops watching
}

@end

#pragma mark - a clip for the track

static void open(NSURL *file) {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:file];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.volume = 0;
    AVPlayerLayer *layer = [AVPlayerLayer layerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    layer.opacity = 0;
    release();
    sg_player = player;
    sg_layer = layer;
    sg_display = [SGRMotionDisplay watching:layer];
    sg_endOfItem = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTime
                                                                    object:item
                                                                     queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(NSNotification *note) {
        if (note.object != player.currentItem) return;
        [player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        [player play];
    }];
    sync();
    [player play];
    SGLog(@"player motion: playing %@", file.lastPathComponent);
}

static void got(NSString *uri, SGCanvas *canvas, NSString *source) {
    SGLog(@"player motion: clip for %@ from %@: %@", uri, source, canvas.address);
    SGArtworkClip(canvas.identifier, canvas.address, ^(NSURL *file, NSString *note) {
        SGLog(@"player motion: %@ %@", canvas.identifier, note);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![sg_wanted isEqualToString:uri] || !file) return;
            SGArtworkCrop(file, canvas.identifier, kCoverAspect, ^(NSURL *ready, NSString *cropNote) {
                SGLog(@"player motion: %@ %@", canvas.identifier, cropNote);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![sg_wanted isEqualToString:uri] || !ready) return;
                    open(ready);
                });
            });
        });
    });
}

// One album's clip, so a queue that runs over the same record, or a shuffle that comes back to it,
// does not ask Apple Music for it again. Only a clip is remembered: from here a search that found
// nothing and a search that failed look alike, and remembering the second would keep an album off the
// cover until the next launch. Those cost one search per track, as the lock screen's own does.
static NSString *sg_askedFor;
static SGCanvas *sg_asked;

static void apple(NSString *uri, NSString *name, void (^done)(SGCanvas *canvas, NSString *note)) {
    if ([sg_askedFor isEqualToString:name]) {
        done(sg_asked, @"answered already");
        return;
    }
    SGAppleArtworkFind(sg_metadata[@"artist_name"] ?: sg_track.artistName, sg_metadata[@"album_title"], NO, ^(SGCanvas *canvas, NSString *note) {
        if (![sg_wanted isEqualToString:uri]) return;
        if (canvas) {
            sg_askedFor = name;
            sg_asked = canvas;
        }
        done(canvas, note);
    });
}

// The sources in the user's order, the first with a clip for the track winning. Spotify's Canvas is
// read out of the track's own metadata, which is where Spotify's core writes it; the canvaz cache
// behind it is the lock screen's to ask (it needs the account's token), so a Canvas only in there is
// not found here until that has fetched it.
static void look(NSString *uri, NSArray<NSString *> *order, NSUInteger at) {
    if (at >= order.count) {
        SGLog(@"player motion: no clip for %@ from %@", uri, order.count ? [order componentsJoinedByString:@", "] : @"no source");
        return;
    }
    NSString *source = order[at];
    if ([source isEqualToString:SGArtworkSourceSpotify]) {
        SGCanvas *canvas = SGCanvasFromMetadata(sg_metadata);
        if (canvas.video) {
            got(uri, canvas, source);
            return;
        }
        SGLog(@"player motion: no clip from %@ for %@ (%@)", source, uri, canvas ? @"a still canvas" : @"no canvas in the metadata");
        look(uri, order, at + 1);
        return;
    }
    NSString *name = [NSString stringWithFormat:@"%@\n%@", sg_metadata[@"artist_name"] ?: sg_track.artistName, sg_metadata[@"album_title"] ?: @""];
    apple(uri, name, ^(SGCanvas *canvas, NSString *note) {
        if (canvas.video) {
            got(uri, canvas, source);
            return;
        }
        SGLog(@"player motion: no clip from %@ for %@ (%@)", source, uri, canvas ? @"a still canvas" : note);
        look(uri, order, at + 1);
    });
}

static void resolve(SPTPlayerTrack *track) {
    // Read on every track, so the switch needs no restart.
    if (!SGFlag(SGRKeyCoverMotion, NO)) {
        if (sg_wanted) {
            sg_wanted = nil;
            release();
            SGLog(@"player motion: switched off");
        }
        return;
    }
    NSString *uri = SGURIString(track.URI);
    if (!uri || [uri isEqualToString:sg_wanted]) return;
    sg_wanted = uri;
    sg_track = track;
    sg_metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    // The old clip is left playing until the new one has a frame to show, so a track with no
    // animation does not leave a black cover behind while its clip is looked for.
    look(uri, SGArtworkOrder(), 0);
}

#pragma mark - what Spotify and the system do

@interface SGRMotionWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRMotionWatcher

- (void)playerStateDidChange:(SPTPlayerState *)state {
    resolve(state.track);
    sync();
}

@end

static SGRMotionWatcher *sg_watcher;

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    sg_watcher = [SGRMotionWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    SGRObservePlayerTransition(sg_watcher, ^(id owner) {
        [sg_player pause];
    }, ^(id owner) {
        // On opening there is a cover to play over, on closing there is none and the clip goes.
        sync();
        if (!SGRPlayerCoverView()) release();
    });
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        [sg_player pause];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        sync();
    }];
    SGLog(@"player motion: on");
}
