/*
 * IsletAudio.c
 *
 * A Core Audio HAL AudioServerPlugIn (user-space audio driver) that publishes one
 * 2-channel loopback device, "Islet Audio".
 *
 *   apps ──► [output stream] ──► volume/mute ──► ring buffer ──► [input stream] ──► Islet
 *
 * Whatever the system mixes into the device's output stream is written (after the
 * device's own volume and mute are applied) into a ring buffer indexed by sample time.
 * The device's input stream reads the same ring back at the input sample time, so a
 * client that records from "Islet Audio" receives the system mix. Islet then applies
 * its EQ and plays the result on the real hardware.
 *
 * Object graph (all IDs are fixed; this plug-in never adds or removes objects):
 *
 *   kAudioObjectPlugInObject (1)    the plug-in
 *     └─ kObjectID_Device (2)       the loopback device
 *          ├─ kObjectID_StreamIn (3)   input stream, 2ch float32
 *          ├─ kObjectID_StreamOut (4)  output stream, 2ch float32
 *          ├─ kObjectID_Volume (5)     output-scope volume control
 *          └─ kObjectID_Mute (6)       output-scope mute control
 *
 * Threading:
 *   - Property access, StartIO/StopIO and configuration changes take gStateMutex.
 *   - The IO path (GetZeroTimeStamp, DoIOOperation) takes no locks. Values it needs that
 *     can change while IO runs (gain, mute) are C11 atomics. Values that only change
 *     while IO is stopped (sample rate, clock anchor) are plain fields: the host only
 *     calls PerformDeviceConfigurationChange with IO stopped, and the clock anchor is
 *     only reset by the StartIO that takes the IO count from 0 to 1.
 *   - Only the IO thread touches the ring buffer and the gain-ramp state.
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <math.h>

#pragma mark - Constants

enum {
    kObjectID_PlugIn    = kAudioObjectPlugInObject,
    kObjectID_Device    = 2,
    kObjectID_StreamIn  = 3,
    kObjectID_StreamOut = 4,
    kObjectID_Volume    = 5,
    kObjectID_Mute      = 6,
};

#define kDeviceName         "Islet Audio"
#define kManufacturerName   "Islet"
#define kDeviceUID          "IsletAudio_UID"
#define kDeviceModelUID     "IsletAudio_ModelUID"

#define kChannelCount       2u
#define kBytesPerSample     ((UInt32)sizeof(Float32))
#define kBytesPerFrame      (kChannelCount * kBytesPerSample)

/* Ring size in frames. It is also the zero-timestamp period, so one "lap" of the ring
 * corresponds to exactly one timestamp period. At 48 kHz this is ~341 ms. */
#define kRingFrames         16384u

static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kSampleRateCount    (sizeof(kSupportedSampleRates) / sizeof(kSupportedSampleRates[0]))
#define kDefaultSampleRate  48000.0

/* Volume control range. The scalar (slider position, 0..1) maps to dB via
 *     dB = kVolumeMinDB * (1 - scalar)^2
 * which is monotonic and exactly invertible, puts half the slider at -16 dB and spends
 * more resolution near the top of the range where the ear is most sensitive. A scalar
 * of exactly 0 is treated as silence rather than -64 dB, so "volume all the way down"
 * is actually quiet. */
#define kVolumeMinDB        (-64.0f)
#define kVolumeMaxDB        (0.0f)

/* Storage keys (the host namespaces them per plug-in). */
#define kStorageKeyVolume       CFSTR("volume")
#define kStorageKeyMute         CFSTR("mute")
#define kStorageKeySampleRate   CFSTR("sample rate")

#pragma mark - Forward declarations (interface methods)

static HRESULT  Islet_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    Islet_AddRef(void* inDriver);
static ULONG    Islet_Release(void* inDriver);
static OSStatus Islet_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Islet_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                   const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus Islet_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Islet_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Islet_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus Islet_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction, void* inChangeInfo);
static OSStatus Islet_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void* inChangeInfo);
static Boolean  Islet_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                  const AudioObjectPropertyAddress* inAddress);
static OSStatus Islet_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus Islet_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                          const void* inQualifierData, UInt32* outDataSize);
static OSStatus Islet_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                      const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus Islet_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                      const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus Islet_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Islet_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Islet_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus Islet_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus Islet_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus Islet_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                    UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus Islet_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - Interface table and driver reference

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,                                       /* _reserved */
    Islet_QueryInterface,
    Islet_AddRef,
    Islet_Release,
    Islet_Initialize,
    Islet_CreateDevice,
    Islet_DestroyDevice,
    Islet_AddDeviceClient,
    Islet_RemoveDeviceClient,
    Islet_PerformDeviceConfigurationChange,
    Islet_AbortDeviceConfigurationChange,
    Islet_HasProperty,
    Islet_IsPropertySettable,
    Islet_GetPropertyDataSize,
    Islet_GetPropertyData,
    Islet_SetPropertyData,
    Islet_StartIO,
    Islet_StopIO,
    Islet_GetZeroTimeStamp,
    Islet_WillDoIOOperation,
    Islet_BeginIOOperation,
    Islet_DoIOOperation,
    Islet_EndIOOperation,
};

/* The driver "object" handed to the host is a pointer to a pointer to the vtable. */
static AudioServerPlugInDriverInterface*  gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef         gDriverRef          = &gDriverInterfacePtr;

#pragma mark - State

/* The plug-in object is statically allocated and lives for the life of the process;
 * the reference count is tracked for COM correctness but never frees anything. */
static _Atomic UInt32           gRefCount = 0;
static AudioServerPlugInHostRef gHost     = NULL;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;

/* Protected by gStateMutex. */
static Float64 gSampleRate       = kDefaultSampleRate;
static UInt32  gIOCount          = 0;     /* number of clients that have called StartIO */
static bool    gStreamInActive   = true;
static bool    gStreamOutActive  = true;

/* Clock. Written by Initialize, PerformDeviceConfigurationChange and the first StartIO;
 * read by GetZeroTimeStamp. Those never overlap (see header comment). */
static Float64 gHostTicksPerSecond = 0.0;
static Float64 gHostTicksPerFrame  = 0.0;
static UInt64  gAnchorHostTime     = 0;
static UInt64  gCycleCount         = 0;

/* Volume/mute: written from property calls, read from the IO thread. */
static _Atomic Float32 gVolumeScalar = 1.0f;
static _Atomic Float32 gVolumeGain   = 1.0f;  /* linear amplitude derived from gVolumeScalar */
static _Atomic bool    gMuted        = false;

/* IO-thread-only state. */
static Float32 gRing[kRingFrames * kChannelCount];
static Float32 gAppliedGain = 1.0f;           /* gain at the end of the previous WriteMix */

#pragma mark - Small helpers

static inline bool IsSupportedSampleRate(Float64 inRate)
{
    for (size_t i = 0; i < kSampleRateCount; i++) {
        if (inRate == kSupportedSampleRates[i]) return true;
    }
    return false;
}

static inline Float32 ClampF(Float32 v, Float32 lo, Float32 hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* Volume curve: see kVolumeMinDB. */
static Float32 VolumeScalarToDB(Float32 inScalar)
{
    Float32 s = ClampF(inScalar, 0.0f, 1.0f);
    Float32 r = 1.0f - s;
    return kVolumeMinDB * r * r;
}

static Float32 VolumeDBToScalar(Float32 inDB)
{
    Float32 db = ClampF(inDB, kVolumeMinDB, kVolumeMaxDB);
    return 1.0f - sqrtf(db / kVolumeMinDB);
}

static Float32 VolumeScalarToGain(Float32 inScalar)
{
    if (inScalar <= 0.0f) return 0.0f;
    return powf(10.0f, VolumeScalarToDB(inScalar) / 20.0f);
}

static void SetVolumeScalar(Float32 inScalar)
{
    Float32 s = ClampF(inScalar, 0.0f, 1.0f);
    atomic_store_explicit(&gVolumeScalar, s, memory_order_relaxed);
    atomic_store_explicit(&gVolumeGain, VolumeScalarToGain(s), memory_order_relaxed);
}

/* Must be called with gStateMutex held, or before the host can call us concurrently. */
static void UpdateClockForSampleRate(Float64 inRate)
{
    gSampleRate        = inRate;
    gHostTicksPerFrame = gHostTicksPerSecond / inRate;
}

static void FillFormat(AudioStreamBasicDescription* outFormat, Float64 inRate)
{
    outFormat->mSampleRate       = inRate;
    outFormat->mFormatID         = kAudioFormatLinearPCM;
    outFormat->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket   = kBytesPerFrame;
    outFormat->mFramesPerPacket  = 1;
    outFormat->mBytesPerFrame    = kBytesPerFrame;
    outFormat->mChannelsPerFrame = kChannelCount;
    outFormat->mBitsPerChannel   = 32;
    outFormat->mReserved         = 0;
}

/* True if the format is ours apart from (possibly) the sample rate. */
static bool IsOurFormatIgnoringRate(const AudioStreamBasicDescription* inFormat)
{
    AudioStreamBasicDescription ours;
    FillFormat(&ours, inFormat->mSampleRate);
    return inFormat->mFormatID == ours.mFormatID
        && inFormat->mFormatFlags == ours.mFormatFlags
        && inFormat->mBytesPerPacket == ours.mBytesPerPacket
        && inFormat->mFramesPerPacket == ours.mFramesPerPacket
        && inFormat->mBytesPerFrame == ours.mBytesPerFrame
        && inFormat->mChannelsPerFrame == ours.mChannelsPerFrame
        && inFormat->mBitsPerChannel == ours.mBitsPerChannel;
}

static Float64 CurrentSampleRate(void)
{
    pthread_mutex_lock(&gStateMutex);
    Float64 rate = gSampleRate;
    pthread_mutex_unlock(&gStateMutex);
    return rate;
}

static inline bool IsDevice(AudioObjectID inID)  { return inID == kObjectID_Device; }
static inline bool IsStream(AudioObjectID inID)  { return inID == kObjectID_StreamIn || inID == kObjectID_StreamOut; }
static inline bool IsControl(AudioObjectID inID) { return inID == kObjectID_Volume || inID == kObjectID_Mute; }

/* Copies as many AudioObjectIDs as fit into outData. Arrays returned from GetPropertyData
 * are truncated to the caller's buffer rather than failing, as the HAL expects. */
static UInt32 CopyIDs(const AudioObjectID* inIDs, UInt32 inCount, UInt32 inDataSize, void* outData)
{
    UInt32 n = inDataSize / (UInt32)sizeof(AudioObjectID);
    if (n > inCount) n = inCount;
    if (n > 0) memcpy(outData, inIDs, n * sizeof(AudioObjectID));
    return n * (UInt32)sizeof(AudioObjectID);
}

/* Lists of child objects for the device, by scope. */
static const AudioObjectID kDeviceStreamsAll[]   = { kObjectID_StreamIn, kObjectID_StreamOut };
static const AudioObjectID kDeviceStreamsIn[]    = { kObjectID_StreamIn };
static const AudioObjectID kDeviceStreamsOut[]   = { kObjectID_StreamOut };
static const AudioObjectID kDeviceControls[]     = { kObjectID_Volume, kObjectID_Mute };
static const AudioObjectID kDeviceOwnedAll[]     = { kObjectID_StreamIn, kObjectID_StreamOut, kObjectID_Volume, kObjectID_Mute };
static const AudioObjectID kDeviceOwnedOut[]     = { kObjectID_StreamOut, kObjectID_Volume, kObjectID_Mute };

static void DeviceStreamsForScope(AudioObjectPropertyScope inScope, const AudioObjectID** outIDs, UInt32* outCount)
{
    switch (inScope) {
        case kAudioObjectPropertyScopeInput:  *outIDs = kDeviceStreamsIn;  *outCount = 1; break;
        case kAudioObjectPropertyScopeOutput: *outIDs = kDeviceStreamsOut; *outCount = 1; break;
        default:                              *outIDs = kDeviceStreamsAll; *outCount = 2; break;
    }
}

static void DeviceOwnedForScope(AudioObjectPropertyScope inScope, const AudioObjectID** outIDs, UInt32* outCount)
{
    switch (inScope) {
        case kAudioObjectPropertyScopeInput:  *outIDs = kDeviceStreamsIn; *outCount = 1; break;
        case kAudioObjectPropertyScopeOutput: *outIDs = kDeviceOwnedOut;  *outCount = 3; break;
        default:                              *outIDs = kDeviceOwnedAll;  *outCount = 4; break;
    }
}

/* Persist a value through the host, if we have one. Never called with gStateMutex held. */
static void StoreFloat(CFStringRef inKey, Float64 inValue)
{
    if (gHost == NULL || gHost->WriteToStorage == NULL) return;
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberFloat64Type, &inValue);
    if (num != NULL) {
        gHost->WriteToStorage(gHost, inKey, num);
        CFRelease(num);
    }
}

static bool LoadFloat(CFStringRef inKey, Float64* outValue)
{
    if (gHost == NULL || gHost->CopyFromStorage == NULL) return false;
    CFPropertyListRef data = NULL;
    bool ok = false;
    if (gHost->CopyFromStorage(gHost, inKey, &data) == 0 && data != NULL) {
        if (CFGetTypeID(data) == CFNumberGetTypeID()) {
            ok = CFNumberGetValue((CFNumberRef)data, kCFNumberFloat64Type, outValue);
        }
    }
    if (data != NULL) CFRelease(data);
    return ok;
}

static void NotifyPropertiesChanged(AudioObjectID inObjectID, UInt32 inCount, const AudioObjectPropertyAddress* inAddresses)
{
    if (gHost != NULL && gHost->PropertiesChanged != NULL) {
        gHost->PropertiesChanged(gHost, inObjectID, inCount, inAddresses);
    }
}

/* Asks the host to schedule a sample-rate change. The new rate rides in inChangeAction
 * (all supported rates are integers), so no allocation is needed for change info. */
static OSStatus RequestSampleRateChange(Float64 inNewRate)
{
    if (!IsSupportedSampleRate(inNewRate)) return kAudioHardwareIllegalOperationError;
    if (inNewRate == CurrentSampleRate()) return kAudioHardwareNoError;
    if (gHost == NULL || gHost->RequestDeviceConfigurationChange == NULL) return kAudioHardwareNotRunningError;
    return gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)inNewRate, NULL);
}

#pragma mark - Factory

/* CFPlugIn factory named in Info.plist. The host calls this with kAudioServerPlugInTypeUUID. */
__attribute__((visibility("default")))
void* IsletAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void* IsletAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (inRequestedTypeUUID == NULL || !CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    atomic_fetch_add(&gRefCount, 1);
    return gDriverRef;
}

#pragma mark - IUnknown

static HRESULT Islet_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;

    HRESULT result;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *outInterface = gDriverRef;
        result = S_OK;
    } else {
        *outInterface = NULL;
        result = E_NOINTERFACE;
    }
    CFRelease(requested);
    return result;
}

static ULONG Islet_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG Islet_Release(void* inDriver)
{
    if (inDriver != gDriverRef) return 0;
    /* Never underflow; the object is static so reaching zero frees nothing. */
    UInt32 old = atomic_load(&gRefCount);
    while (old > 0 && !atomic_compare_exchange_weak(&gRefCount, &old, old - 1)) { }
    return old > 0 ? old - 1 : 0;
}

#pragma mark - Basic operations

static OSStatus Islet_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gHostTicksPerSecond = 1.0e9 * (Float64)tb.denom / (Float64)tb.numer;

    /* Restore persisted settings, falling back to defaults. */
    Float64 rate = kDefaultSampleRate, volume = 1.0, mute = 0.0;
    if (!LoadFloat(kStorageKeySampleRate, &rate) || !IsSupportedSampleRate(rate)) rate = kDefaultSampleRate;
    if (!LoadFloat(kStorageKeyVolume, &volume) || !(volume >= 0.0 && volume <= 1.0)) volume = 1.0;
    (void)LoadFloat(kStorageKeyMute, &mute);

    pthread_mutex_lock(&gStateMutex);
    UpdateClockForSampleRate(rate);
    pthread_mutex_unlock(&gStateMutex);

    SetVolumeScalar((Float32)volume);
    atomic_store(&gMuted, mute != 0.0);
    gAppliedGain = atomic_load(&gMuted) ? 0.0f : atomic_load(&gVolumeGain);
    return kAudioHardwareNoError;
}

static OSStatus Islet_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                   const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    return kAudioHardwareUnsupportedOperationError;   /* the device is static */
}

static OSStatus Islet_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDeviceObjectID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Islet_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus Islet_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

/* Called by the host (with IO stopped) after we asked for a change via
 * RequestDeviceConfigurationChange. The only change we request is a sample-rate change,
 * whose new rate is carried in inChangeAction. The host re-reads device state afterwards. */
static OSStatus Islet_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                       UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;

    Float64 rate = (Float64)inChangeAction;
    if (!IsSupportedSampleRate(rate)) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gStateMutex);
    UpdateClockForSampleRate(rate);
    pthread_mutex_unlock(&gStateMutex);

    StoreFloat(kStorageKeySampleRate, rate);
    return kAudioHardwareNoError;
}

static OSStatus Islet_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    return kAudioHardwareNoError;   /* nothing was allocated for the request */
}

#pragma mark - Property dispatch: plug-in

static Boolean PlugIn_HasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyClockDeviceList:
        case kAudioPlugInPropertyTranslateUIDToClockDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static OSStatus PlugIn_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToClockDevice:
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList:
            *outDataSize = 0; return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus PlugIn_GetPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                       const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID*)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID*)outData = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID*)outData = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef*)outData = CFSTR(kManufacturerName);
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            static const AudioObjectID devices[] = { kObjectID_Device };
            *outDataSize = CopyIDs(devices, 1, inDataSize, outData);
            return kAudioHardwareNoError;
        }

        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList:
            *outDataSize = 0;
            return kAudioHardwareNoError;

        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToClockDevice: {
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef*)inQualifierData;
            AudioObjectID result = kAudioObjectUnknown;
            if (inAddress->mSelector == kAudioPlugInPropertyTranslateUIDToDevice && uid != NULL
                && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) {
                result = kObjectID_Device;
            }
            *(AudioObjectID*)outData = result;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }

        case kAudioPlugInPropertyResourceBundle:
            /* Path relative to our bundle's Resources; empty means the bundle itself. */
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef*)outData = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Property dispatch: device

static Boolean Device_HasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyClockIsStable:
            return true;

        /* Channel-layout properties only make sense in a directional scope. */
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return inAddress->mScope == kAudioObjectPropertyScopeInput
                || inAddress->mScope == kAudioObjectPropertyScopeOutput;

        default:
            return false;
    }
}

static OSStatus Device_IsPropertySettable(const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    if (!Device_HasProperty(inAddress)) return kAudioHardwareUnknownPropertyError;
    *outIsSettable = (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate);
    return kAudioHardwareNoError;
}

static UInt32 ChannelLayoutSize(void)
{
    return (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription));
}

static OSStatus Device_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize)
{
    const AudioObjectID* ids; UInt32 count;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            DeviceOwnedForScope(inAddress->mScope, &ids, &count);
            *outDataSize = count * (UInt32)sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
            DeviceStreamsForScope(inAddress->mScope, &ids, &count);
            *outDataSize = count * (UInt32)sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *outDataSize = 2 * (UInt32)sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyClockIsStable:
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = (UInt32)(kSampleRateCount * sizeof(AudioValueRange)); return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (!Device_HasProperty(inAddress)) return kAudioHardwareUnknownPropertyError;
            *outDataSize = 2 * sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout:
            if (!Device_HasProperty(inAddress)) return kAudioHardwareUnknownPropertyError;
            *outDataSize = ChannelLayoutSize(); return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#define RETURN_UINT32(value) do { \
        if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError; \
        *(UInt32*)outData = (UInt32)(value); *outDataSize = sizeof(UInt32); \
        return kAudioHardwareNoError; } while (0)

#define RETURN_CFSTRING(value) do { \
        if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; \
        *(CFStringRef*)outData = (value); *outDataSize = sizeof(CFStringRef); \
        return kAudioHardwareNoError; } while (0)

static OSStatus Device_GetPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize,
                                       UInt32* outDataSize, void* outData)
{
    const AudioObjectID* ids; UInt32 count;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:     RETURN_UINT32(kAudioObjectClassID);
        case kAudioObjectPropertyClass:         RETURN_UINT32(kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:         RETURN_UINT32(kObjectID_PlugIn);
        case kAudioObjectPropertyName:          RETURN_CFSTRING(CFSTR(kDeviceName));
        case kAudioObjectPropertyManufacturer:  RETURN_CFSTRING(CFSTR(kManufacturerName));
        case kAudioDevicePropertyDeviceUID:     RETURN_CFSTRING(CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID:      RETURN_CFSTRING(CFSTR(kDeviceModelUID));

        case kAudioObjectPropertyOwnedObjects:
            DeviceOwnedForScope(inAddress->mScope, &ids, &count);
            *outDataSize = CopyIDs(ids, count, inDataSize, outData);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyStreams:
            DeviceStreamsForScope(inAddress->mScope, &ids, &count);
            *outDataSize = CopyIDs(ids, count, inDataSize, outData);
            return kAudioHardwareNoError;

        case kAudioObjectPropertyControlList:
            *outDataSize = CopyIDs(kDeviceControls, 2, inDataSize, outData);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyRelatedDevices: {
            static const AudioObjectID self[] = { kObjectID_Device };
            *outDataSize = CopyIDs(self, 1, inDataSize, outData);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyTransportType: RETURN_UINT32(kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain:   RETURN_UINT32(0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_UINT32(1);

        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOCount > 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_UINT32(running);
        }

        /* Default output: yes. Default input: never; this must not become the mic. */
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            RETURN_UINT32(inAddress->mScope != kAudioObjectPropertyScopeInput);

        /* The system (alert) device is an output concept; same rule as above. */
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            RETURN_UINT32(inAddress->mScope != kAudioObjectPropertyScopeInput);

        case kAudioDevicePropertyLatency:           RETURN_UINT32(0);
        case kAudioDevicePropertySafetyOffset:      RETURN_UINT32(0);
        case kAudioDevicePropertyIsHidden:          RETURN_UINT32(0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_UINT32(kRingFrames);
        case kAudioDevicePropertyClockIsStable:     RETURN_UINT32(1);

        case kAudioDevicePropertyNominalSampleRate:
            if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            *(Float64*)outData = CurrentSampleRate();
            *outDataSize = sizeof(Float64);
            return kAudioHardwareNoError;

        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 n = inDataSize / (UInt32)sizeof(AudioValueRange);
            if (n > kSampleRateCount) n = (UInt32)kSampleRateCount;
            AudioValueRange* ranges = (AudioValueRange*)outData;
            for (UInt32 i = 0; i < n; i++) {
                ranges[i].mMinimum = kSupportedSampleRates[i];
                ranges[i].mMaximum = kSupportedSampleRates[i];
            }
            *outDataSize = n * (UInt32)sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (!Device_HasProperty(inAddress)) return kAudioHardwareUnknownPropertyError;
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }

        case kAudioDevicePropertyPreferredChannelLayout: {
            if (!Device_HasProperty(inAddress)) return kAudioHardwareUnknownPropertyError;
            UInt32 size = ChannelLayoutSize();
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mChannelBitmap = 0;
            layout->mNumberChannelDescriptions = kChannelCount;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = size;
            return kAudioHardwareNoError;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Device_SetPropertyData(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, const void* inData)
{
    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            return RequestSampleRateChange(*(const Float64*)inData);
        default:
            return Device_HasProperty(inAddress) ? kAudioHardwareUnsupportedOperationError
                                                 : kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Property dispatch: streams

static Boolean Stream_HasProperty(const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static OSStatus Stream_IsPropertySettable(const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    if (!Stream_HasProperty(inAddress)) return kAudioHardwareUnknownPropertyError;
    switch (inAddress->mSelector) {
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true; break;
        default:
            *outIsSettable = false; break;
    }
    return kAudioHardwareNoError;
}

static OSStatus Stream_GetPropertyDataSize(const AudioObjectPropertyAddress* inAddress, UInt32* outDataSize)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription); return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = (UInt32)(kSampleRateCount * sizeof(AudioStreamRangedDescription)); return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Stream_GetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                       UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    const bool isInput = (inObjectID == kObjectID_StreamIn);
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_UINT32(kAudioObjectClassID);
        case kAudioObjectPropertyClass:     RETURN_UINT32(kAudioStreamClassID);
        case kAudioObjectPropertyOwner:     RETURN_UINT32(kObjectID_Device);

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;

        case kAudioObjectPropertyName:
            RETURN_CFSTRING(isInput ? CFSTR("Islet Loopback Input") : CFSTR("Islet Output"));

        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 active = isInput ? gStreamInActive : gStreamOutActive;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_UINT32(active);
        }

        case kAudioStreamPropertyDirection:     RETURN_UINT32(isInput ? 1 : 0);   /* 1 = input, 0 = output */
        case kAudioStreamPropertyTerminalType:
            RETURN_UINT32(isInput ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_UINT32(1);
        case kAudioStreamPropertyLatency:       RETURN_UINT32(0);

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            FillFormat((AudioStreamBasicDescription*)outData, CurrentSampleRate());
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 n = inDataSize / (UInt32)sizeof(AudioStreamRangedDescription);
            if (n > kSampleRateCount) n = (UInt32)kSampleRateCount;
            AudioStreamRangedDescription* descs = (AudioStreamRangedDescription*)outData;
            for (UInt32 i = 0; i < n; i++) {
                FillFormat(&descs[i].mFormat, kSupportedSampleRates[i]);
                descs[i].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                descs[i].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
            }
            *outDataSize = n * (UInt32)sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Stream_SetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                       UInt32 inDataSize, const void* inData)
{
    switch (inAddress->mSelector) {
        case kAudioStreamPropertyIsActive: {
            if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            bool active = *(const UInt32*)inData != 0;
            bool changed;
            pthread_mutex_lock(&gStateMutex);
            bool* slot = (inObjectID == kObjectID_StreamIn) ? &gStreamInActive : &gStreamOutActive;
            changed = (*slot != active);
            *slot = active;
            pthread_mutex_unlock(&gStateMutex);
            if (changed) {
                AudioObjectPropertyAddress addr = { kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal,
                                                    kAudioObjectPropertyElementMain };
                NotifyPropertiesChanged(inObjectID, 1, &addr);
            }
            return kAudioHardwareNoError;
        }

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription* fmt = (const AudioStreamBasicDescription*)inData;
            if (!IsOurFormatIgnoringRate(fmt) || !IsSupportedSampleRate(fmt->mSampleRate)) {
                return kAudioDeviceUnsupportedFormatError;
            }
            return RequestSampleRateChange(fmt->mSampleRate);
        }

        default:
            return Stream_HasProperty(inAddress) ? kAudioHardwareUnsupportedOperationError
                                                 : kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Property dispatch: controls

static Boolean Control_HasProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress)
{
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
            return true;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            return inObjectID == kObjectID_Volume;
        case kAudioBooleanControlPropertyValue:
            return inObjectID == kObjectID_Mute;
        default:
            return false;
    }
}

static OSStatus Control_IsPropertySettable(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                           Boolean* outIsSettable)
{
    if (!Control_HasProperty(inObjectID, inAddress)) return kAudioHardwareUnknownPropertyError;
    switch (inAddress->mSelector) {
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioBooleanControlPropertyValue:
            *outIsSettable = true; break;
        default:
            *outIsSettable = false; break;
    }
    return kAudioHardwareNoError;
}

static OSStatus Control_GetPropertyDataSize(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                            UInt32* outDataSize)
{
    if (!Control_HasProperty(inObjectID, inAddress)) return kAudioHardwareUnknownPropertyError;
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0; return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            *outDataSize = sizeof(AudioObjectPropertyScope); return kAudioHardwareNoError;
        case kAudioControlPropertyElement:
            *outDataSize = sizeof(AudioObjectPropertyElement); return kAudioHardwareNoError;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
        case kAudioLevelControlPropertyDecibelRange:
            *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
        case kAudioBooleanControlPropertyValue:
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#define RETURN_FLOAT32(value) do { \
        if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError; \
        *(Float32*)outData = (Float32)(value); *outDataSize = sizeof(Float32); \
        return kAudioHardwareNoError; } while (0)

static OSStatus Control_GetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    if (!Control_HasProperty(inObjectID, inAddress)) return kAudioHardwareUnknownPropertyError;
    const bool isVolume = (inObjectID == kObjectID_Volume);
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            RETURN_UINT32(isVolume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
        case kAudioObjectPropertyClass:
            RETURN_UINT32(isVolume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
        case kAudioObjectPropertyOwner:
            RETURN_UINT32(kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioControlPropertyScope:
            RETURN_UINT32(kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement:
            RETURN_UINT32(kAudioObjectPropertyElementMain);

        case kAudioLevelControlPropertyScalarValue:
            RETURN_FLOAT32(atomic_load_explicit(&gVolumeScalar, memory_order_relaxed));
        case kAudioLevelControlPropertyDecibelValue:
            RETURN_FLOAT32(VolumeScalarToDB(atomic_load_explicit(&gVolumeScalar, memory_order_relaxed)));
        case kAudioLevelControlPropertyDecibelRange:
            if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
            ((AudioValueRange*)outData)->mMinimum = kVolumeMinDB;
            ((AudioValueRange*)outData)->mMaximum = kVolumeMaxDB;
            *outDataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;

        /* The conversion properties are in/out: outData holds the input value. */
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            RETURN_FLOAT32(VolumeScalarToDB(*(Float32*)outData));
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            RETURN_FLOAT32(VolumeDBToScalar(*(Float32*)outData));

        case kAudioBooleanControlPropertyValue:
            RETURN_UINT32(atomic_load_explicit(&gMuted, memory_order_relaxed) ? 1 : 0);

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus Control_SetPropertyData(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inDataSize, const void* inData)
{
    if (!Control_HasProperty(inObjectID, inAddress)) return kAudioHardwareUnknownPropertyError;
    switch (inAddress->mSelector) {
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue: {
            if (inDataSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 value = *(const Float32*)inData;
            if (isnan(value)) return kAudioHardwareIllegalOperationError;
            Float32 scalar = (inAddress->mSelector == kAudioLevelControlPropertyScalarValue)
                           ? ClampF(value, 0.0f, 1.0f) : VolumeDBToScalar(value);
            Float32 old = atomic_load_explicit(&gVolumeScalar, memory_order_relaxed);
            if (scalar != old) {
                SetVolumeScalar(scalar);
                StoreFloat(kStorageKeyVolume, scalar);
                AudioObjectPropertyAddress addrs[2] = {
                    { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                    { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                };
                NotifyPropertiesChanged(kObjectID_Volume, 2, addrs);
            }
            return kAudioHardwareNoError;
        }

        case kAudioBooleanControlPropertyValue: {
            if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            bool mute = *(const UInt32*)inData != 0;
            bool old = atomic_exchange_explicit(&gMuted, mute, memory_order_relaxed);
            if (mute != old) {
                StoreFloat(kStorageKeyMute, mute ? 1.0 : 0.0);
                AudioObjectPropertyAddress addr = { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
                                                    kAudioObjectPropertyElementMain };
                NotifyPropertiesChanged(kObjectID_Mute, 1, &addr);
            }
            return kAudioHardwareNoError;
        }

        default:
            return kAudioHardwareUnsupportedOperationError;
    }
}

#pragma mark - Property operations (entry points)

static Boolean Islet_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress* inAddress)
{
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    if (inObjectID == kObjectID_PlugIn) return PlugIn_HasProperty(inAddress);
    if (IsDevice(inObjectID))           return Device_HasProperty(inAddress);
    if (IsStream(inObjectID))           return Stream_HasProperty(inAddress);
    if (IsControl(inObjectID))          return Control_HasProperty(inObjectID, inAddress);
    return false;
}

static OSStatus Islet_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_PlugIn) {
        if (!PlugIn_HasProperty(inAddress)) return kAudioHardwareUnknownPropertyError;
        *outIsSettable = false;
        return kAudioHardwareNoError;
    }
    if (IsDevice(inObjectID))  return Device_IsPropertySettable(inAddress, outIsSettable);
    if (IsStream(inObjectID))  return Stream_IsPropertySettable(inAddress, outIsSettable);
    if (IsControl(inObjectID)) return Control_IsPropertySettable(inObjectID, inAddress, outIsSettable);
    return kAudioHardwareBadObjectError;
}

static OSStatus Islet_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                          const void* inQualifierData, UInt32* outDataSize)
{
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_PlugIn) return PlugIn_GetPropertyDataSize(inAddress, outDataSize);
    if (IsDevice(inObjectID))           return Device_GetPropertyDataSize(inAddress, outDataSize);
    if (IsStream(inObjectID))           return Stream_GetPropertyDataSize(inAddress, outDataSize);
    if (IsControl(inObjectID))          return Control_GetPropertyDataSize(inObjectID, inAddress, outDataSize);
    return kAudioHardwareBadObjectError;
}

static OSStatus Islet_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                      const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || (outData == NULL && inDataSize > 0)) {
        return kAudioHardwareIllegalOperationError;
    }

    if (inObjectID == kObjectID_PlugIn) {
        return PlugIn_GetPropertyData(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
    }
    if (IsDevice(inObjectID))  return Device_GetPropertyData(inAddress, inDataSize, outDataSize, outData);
    if (IsStream(inObjectID))  return Stream_GetPropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
    if (IsControl(inObjectID)) return Control_GetPropertyData(inObjectID, inAddress, inDataSize, outDataSize, outData);
    return kAudioHardwareBadObjectError;
}

static OSStatus Islet_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize,
                                      const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_PlugIn) {
        return PlugIn_HasProperty(inAddress) ? kAudioHardwareUnsupportedOperationError
                                             : kAudioHardwareUnknownPropertyError;
    }
    if (IsDevice(inObjectID))  return Device_SetPropertyData(inAddress, inDataSize, inData);
    if (IsStream(inObjectID))  return Stream_SetPropertyData(inObjectID, inAddress, inDataSize, inData);
    if (IsControl(inObjectID)) return Control_SetPropertyData(inObjectID, inAddress, inDataSize, inData);
    return kAudioHardwareBadObjectError;
}

#pragma mark - IO operations

static OSStatus Islet_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;

    OSStatus result = kAudioHardwareNoError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == UINT32_MAX) {
        result = kAudioHardwareIllegalOperationError;
    } else if (gIOCount++ == 0) {
        /* First client: start the clock and begin from silence. The IO thread is not yet
         * running for this device, so touching the ring and clock here is safe. */
        memset(gRing, 0, sizeof(gRing));
        gAnchorHostTime = mach_absolute_time();
        gCycleCount = 0;
        gAppliedGain = atomic_load(&gMuted) ? 0.0f : atomic_load(&gVolumeGain);
    }
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

static OSStatus Islet_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;

    OSStatus result = kAudioHardwareNoError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) result = kAudioHardwareIllegalOperationError;
    else gIOCount--;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

/* Reports the most recent zero timestamp: the host time at which the ring last wrapped
 * to sample time (cycle * kRingFrames). The clock is free-running from the anchor taken
 * in StartIO, with a period of kRingFrames frames converted to host ticks. */
static OSStatus Islet_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;

    const Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kRingFrames;
    const UInt64  now = mach_absolute_time();

    /* Advance past every period boundary that has already elapsed. Normally this runs at
     * most once per call; the loop also catches up after a long stall. */
    while ((Float64)gAnchorHostTime + (Float64)(gCycleCount + 1) * ticksPerPeriod <= (Float64)now) {
        gCycleCount++;
    }

    *outSampleTime = (Float64)gCycleCount * (Float64)kRingFrames;
    *outHostTime   = gAnchorHostTime + (UInt64)((Float64)gCycleCount * ticksPerPeriod);
    *outSeed       = 1;
    return kAudioHardwareNoError;
}

static OSStatus Islet_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                        UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;

    bool willDo = (inOperationID == kAudioServerPlugInIOOperationReadInput
                || inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo != NULL)        *outWillDo = willDo;
    if (outWillDoInPlace != NULL) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Islet_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                       UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                       const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    return kAudioHardwareNoError;
}

static OSStatus Islet_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    return kAudioHardwareNoError;
}

/* Maps a (possibly negative or fractional) sample time onto a ring frame index. */
static inline UInt32 RingIndex(Float64 inSampleTime)
{
    SInt64 t = (SInt64)floor(inSampleTime);
    SInt64 m = t % (SInt64)kRingFrames;
    return (UInt32)(m < 0 ? m + kRingFrames : m);
}

/* Output side: apply volume/mute and store the system mix into the ring. The gain is
 * ramped linearly across the buffer from the previous value to avoid zipper noise when
 * the volume keys are pressed. */
static void WriteMixToRing(const Float32* inSamples, UInt32 inFrames, Float64 inSampleTime)
{
    const Float32 target = atomic_load_explicit(&gMuted, memory_order_relaxed)
                         ? 0.0f : atomic_load_explicit(&gVolumeGain, memory_order_relaxed);
    const Float32 start = gAppliedGain;
    const Float32 step  = (inFrames > 0) ? (target - start) / (Float32)inFrames : 0.0f;

    UInt32 pos = RingIndex(inSampleTime);
    Float32 g = start;
    for (UInt32 f = 0; f < inFrames; f++) {
        g += step;
        Float32* dst = &gRing[pos * kChannelCount];
        const Float32* src = &inSamples[f * kChannelCount];
        dst[0] = src[0] * g;
        dst[1] = src[1] * g;
        if (++pos == kRingFrames) pos = 0;
    }
    gAppliedGain = target;
}

/* Input side: copy the ring at the input sample time, then clear what was read. The
 * clear matters when nothing is being played: the host may skip WriteMix when there are
 * no output clients, and without it the reader would loop the last ring's worth of audio.
 * Input time always trails output time, so the cleared region is never one that is still
 * waiting to be read. */
static void ReadInputFromRing(Float32* outSamples, UInt32 inFrames, Float64 inSampleTime)
{
    UInt32 pos = RingIndex(inSampleTime);
    UInt32 remaining = inFrames;
    Float32* dst = outSamples;
    while (remaining > 0) {
        UInt32 chunk = kRingFrames - pos;
        if (chunk > remaining) chunk = remaining;
        size_t bytes = (size_t)chunk * kBytesPerFrame;
        memcpy(dst, &gRing[pos * kChannelCount], bytes);
        memset(&gRing[pos * kChannelCount], 0, bytes);
        dst += chunk * kChannelCount;
        remaining -= chunk;
        pos = 0;
    }
}

static OSStatus Islet_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                    UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                    const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    if (!IsStream(inStreamObjectID)) return kAudioHardwareBadStreamError;
    if (inIOCycleInfo == NULL || ioMainBuffer == NULL) return kAudioHardwareIllegalOperationError;

    /* A buffer larger than the ring cannot be represented; clamp defensively. */
    UInt32 frames = inIOBufferFrameSize > kRingFrames ? kRingFrames : inIOBufferFrameSize;

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationWriteMix:
            if (inStreamObjectID == kObjectID_StreamOut) {
                WriteMixToRing((const Float32*)ioMainBuffer, frames, inIOCycleInfo->mOutputTime.mSampleTime);
            }
            break;
        case kAudioServerPlugInIOOperationReadInput:
            if (inStreamObjectID == kObjectID_StreamIn) {
                ReadInputFromRing((Float32*)ioMainBuffer, frames, inIOCycleInfo->mInputTime.mSampleTime);
                if (frames < inIOBufferFrameSize) {
                    memset((Float32*)ioMainBuffer + frames * kChannelCount, 0,
                           (size_t)(inIOBufferFrameSize - frames) * kBytesPerFrame);
                }
            }
            break;
        default:
            break;
    }
    return kAudioHardwareNoError;
}
