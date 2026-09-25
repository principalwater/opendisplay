#import "CGVirtualDisplayPrivate.h"

#include <sys/file.h>
#include <sys/stat.h>

static inline int ODLockFile(int descriptor) {
    return flock(descriptor, LOCK_EX);
}

static inline int ODUnlockFile(int descriptor) {
    return flock(descriptor, LOCK_UN);
}

static inline bool ODFileDescriptorPointsToPath(int descriptor, const char *path) {
    struct stat descriptorInfo;
    struct stat pathInfo;
    return fstat(descriptor, &descriptorInfo) == 0
        && stat(path, &pathInfo) == 0
        && descriptorInfo.st_dev == pathInfo.st_dev
        && descriptorInfo.st_ino == pathInfo.st_ino;
}

// MARK: - Raw CGEvent access for the magnify (pinch-zoom) gesture
//
// macOS has no public constructor for a trackpad magnify gesture. The window
// server synthesises `NSEventTypeMagnify` from an IOHIDEvent, and the only way
// to inject one is the same undocumented path Mac Mouse Fix uses: a CGEvent
// whose *type* is `kCGEventGesture` (29) carrying three private fields —
// gesture type (110), magnification (113) and IOHIDEvent phase (132).
//
// None of those numbers exist in the Swift-imported `CGEventType` /
// `CGEventField` enums, and Swift's `init?(rawValue:)` answers nil for a value
// that names no case. Casting an out-of-range value into a frozen Swift enum is
// undefined behaviour the optimiser is entitled to act on, so the cast happens
// here, in C, where an enum is an integer and nothing is being promised.
//
// Private API, exactly like CGVirtualDisplay above: personal build only. Every
// field this touches is a *write* on an event we created, never a read of
// system state, so the failure mode of a future macOS renumbering them is an
// event the window server ignores — the `zoomMode keys` fallback is one
// defaults write away.

/// `kCGEventGesture` — the CGEvent type NSEvent turns into gesture events.
static const uint32_t ODEventTypeGesture = 29;
/// `kCGEventGestureType` — which gesture this is (see `ODGestureTypeZoom`).
static const uint32_t ODEventFieldGestureType = 110;
/// The zoom delta, as a double: the *incremental* magnification, i.e. what
/// `NSEvent.magnification` reports (0.01 = 1% bigger), not a scale factor.
static const uint32_t ODEventFieldGestureZoomDelta = 113;
/// `IOHIDEventPhaseBits` for the gesture: began / changed / ended / cancelled.
static const uint32_t ODEventFieldGesturePhase = 132;
/// `kIOHIDEventTypeZoom`.
static const int64_t ODGestureTypeZoom = 28;

/// A `kCGEventGesture` event. Returns +1, so Swift owns it.
CF_RETURNS_RETAINED
static inline _Nullable CGEventRef ODCreateGestureEvent(CGEventSourceRef _Nullable source) {
    CGEventRef event = CGEventCreate(source);
    if (event) { CGEventSetType(event, (CGEventType)ODEventTypeGesture); }
    return event;
}

static inline void ODSetEventIntegerField(CGEventRef event, uint32_t field, int64_t value) {
    CGEventSetIntegerValueField(event, (CGEventField)field, value);
}

static inline void ODSetEventDoubleField(CGEventRef event, uint32_t field, double value) {
    CGEventSetDoubleValueField(event, (CGEventField)field, value);
}

static inline int64_t ODGetEventIntegerField(CGEventRef event, uint32_t field) {
    return CGEventGetIntegerValueField(event, (CGEventField)field);
}

static inline double ODGetEventDoubleField(CGEventRef event, uint32_t field) {
    return CGEventGetDoubleValueField(event, (CGEventField)field);
}

/// `CGEventGetType` as an integer, so a test can assert a type Swift's enum
/// cannot name.
static inline uint32_t ODGetEventTypeRaw(CGEventRef event) {
    return (uint32_t)CGEventGetType(event);
}
