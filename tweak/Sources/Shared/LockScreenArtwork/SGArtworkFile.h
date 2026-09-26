// The clip on disk: fetched once into Caches, reshaped once for the now playing key, and kept until
// the cap pushes the oldest out. Everything answers off the main thread.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// `done` gets the local file, or nil with `note` saying why. The fetch in flight is dropped first.
void SGArtworkFetch(NSString *identifier, NSString *address, void (^done)(NSURL *file, NSString *note));
void SGArtworkCancelFetch(void);
// The same clip without taking the download away from whoever has it: the mod fetches one clip at a
// time and SGArtworkFetch cancels the one in flight, so this answers what is on disk, and while
// another fetch is running it answers nil and says so rather than cancelling it. For a screen that
// plays the clip (Redesigned/Player's cover) where the lock screen's clip has first claim on it.
void SGArtworkClip(NSString *identifier, NSString *address, void (^done)(NSURL *file, NSString *note));
// The clip centre cropped to `aspect`, width over height. A clip already that shape comes back as it is.
void SGArtworkCrop(NSURL *file, NSString *identifier, CGFloat aspect, void (^done)(NSURL *cropped, NSString *note));
// The clip's first frame, which the system wants the preview still to match; NULL when unreadable.
void SGArtworkFirstFrame(NSURL *file, void (^done)(CGImageRef frame));
