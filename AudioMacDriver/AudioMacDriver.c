// AudioMac Loopback — driver audio virtuale (AudioServerPlugIn) per macOS 11 e 12.
//
// Espone un dispositivo "AudioMac Loopback" con un'uscita e un ingresso stereo:
// tutto ciò che viene riprodotto sull'uscita è disponibile sull'ingresso.
// L'app lo usa solo dove ScreenCaptureKit non può catturare l'audio di sistema (macOS < 13).
//
// Struttura basata sull'esempio "NullAudio" di Apple (Creating an Audio Server Driver Plug-in).

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <math.h>
#include <string.h>

#define kManufacturerName "AudioMac"
#define kDeviceName       "AudioMac Loopback"
#define kDeviceUID        "AudioMacLoopback_UID"
#define kDeviceModelUID   "AudioMacLoopback_ModelUID"

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3,
    kObjectID_Stream_Output = 4,
};

#define kChannelCount  2
#define kBytesPerFrame (sizeof(Float32) * kChannelCount)
#define kRingFrames    16384

static const Float64 kSupportedRates[] = { 44100.0, 48000.0 };
#define kSupportedRateCount (sizeof(kSupportedRates) / sizeof(kSupportedRates[0]))

// MARK: - Stato

static pthread_mutex_t          gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32                   gRefCount = 0;
static Float64                  gSampleRate = 48000.0;
static Float64                  gHostTicksPerFrame = 0;
static UInt32                   gIOClients = 0;
static UInt64                   gAnchorHostTime = 0;
static UInt64                   gTimeStampCount = 0;
static UInt32                   gInputActive = 1;
static UInt32                   gOutputActive = 1;

// Accessibili solo dal thread di IO.
static Float32 gRing[kRingFrames * kChannelCount];
static Float64 gWrittenUntil = 0; // sample time (esclusivo) fino a cui l'uscita ha scritto nel ring

static void UpdateHostTicksPerFrame(void) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 hostClockFrequency = (Float64)timebase.denom / (Float64)timebase.numer * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / gSampleRate;
}

static Boolean IsSupportedRate(Float64 rate) {
    for (UInt32 i = 0; i < kSupportedRateCount; i++) {
        if (rate == kSupportedRates[i]) return true;
    }
    return false;
}

static AudioStreamBasicDescription MakeFormat(Float64 rate) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate       = rate;
    format.mFormatID         = kAudioFormatLinearPCM;
    format.mFormatFlags      = kAudioFormatFlagsNativeFloatPacked;
    format.mBytesPerPacket   = kBytesPerFrame;
    format.mFramesPerPacket  = 1;
    format.mBytesPerFrame    = kBytesPerFrame;
    format.mChannelsPerFrame = kChannelCount;
    format.mBitsPerChannel   = 32;
    return format;
}

// MARK: - Interfaccia

static HRESULT  QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    AddRef(void* inDriver);
static ULONG    Release(void* inDriver);
static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef = &gInterfacePtr;

// MARK: - Factory (dichiarata in Info.plist → CFPlugInFactories)

__attribute__((visibility("default")))
void* AudioMac_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

// MARK: - IUnknown

static HRESULT QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareIllegalOperationError;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

// MARK: - Ciclo di vita

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    pthread_mutex_lock(&gStateMutex);
    UpdateHostTicksPerFrame();
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

// L'unica modifica di configurazione è il cambio di sample rate: inChangeAction contiene il nuovo valore.
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    Float64 rate = (Float64)inChangeAction;
    if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    gSampleRate = rate;
    UpdateHostTicksPerFrame();
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

// MARK: - Proprietà

// Scrive un valore scalare; con outData == NULL restituisce solo la dimensione.
#define WRITE_VALUE(type, value)                                                        \
    do {                                                                                \
        if (outData != NULL) {                                                          \
            if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError;   \
            *((type*)outData) = (value);                                                \
        }                                                                               \
        *outDataSize = sizeof(type);                                                    \
        return kAudioHardwareNoError;                                                   \
    } while (0)

// Scrive un array di elementi, troncandolo alla dimensione del buffer ricevuto.
static OSStatus WriteArray(const void* items, UInt32 count, UInt32 itemSize, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (outData == NULL) {
        *outDataSize = count * itemSize;
        return kAudioHardwareNoError;
    }
    UInt32 fit = inDataSize / itemSize;
    if (fit > count) fit = count;
    if (fit > 0) memcpy(outData, items, fit * itemSize);
    *outDataSize = fit * itemSize;
    return kAudioHardwareNoError;
}

static OSStatus PlugInProperty(const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData,
                               UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    static const AudioObjectID devices[] = { kObjectID_Device };

    switch (inAddress->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer:
        WRITE_VALUE(CFStringRef, CFSTR(kManufacturerName));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
        return WriteArray(devices, 1, sizeof(AudioObjectID), inDataSize, outDataSize, outData);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID device = kAudioObjectUnknown;
        if (outData != NULL) {
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef*)inQualifierData;
            if (uid != NULL && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) device = kObjectID_Device;
        }
        WRITE_VALUE(AudioObjectID, device);
    }
    case kAudioPlugInPropertyResourceBundle:
        WRITE_VALUE(CFStringRef, CFSTR(""));
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    static const AudioObjectID allStreams[]    = { kObjectID_Stream_Input, kObjectID_Stream_Output };
    static const AudioObjectID inputStreams[]  = { kObjectID_Stream_Input };
    static const AudioObjectID outputStreams[] = { kObjectID_Stream_Output };
    static const AudioObjectID related[]       = { kObjectID_Device };

    switch (inAddress->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, kObjectID_PlugIn);
    case kAudioObjectPropertyName:
        WRITE_VALUE(CFStringRef, CFSTR(kDeviceName));
    case kAudioObjectPropertyManufacturer:
        WRITE_VALUE(CFStringRef, CFSTR(kManufacturerName));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams:
        switch (inAddress->mScope) {
        case kAudioObjectPropertyScopeInput:
            return WriteArray(inputStreams, 1, sizeof(AudioObjectID), inDataSize, outDataSize, outData);
        case kAudioObjectPropertyScopeOutput:
            return WriteArray(outputStreams, 1, sizeof(AudioObjectID), inDataSize, outDataSize, outData);
        default:
            return WriteArray(allStreams, 2, sizeof(AudioObjectID), inDataSize, outDataSize, outData);
        }
    case kAudioObjectPropertyControlList:
        return WriteArray(NULL, 0, sizeof(AudioObjectID), inDataSize, outDataSize, outData);
    case kAudioDevicePropertyDeviceUID:
        WRITE_VALUE(CFStringRef, CFSTR(kDeviceUID));
    case kAudioDevicePropertyModelUID:
        WRITE_VALUE(CFStringRef, CFSTR(kDeviceModelUID));
    case kAudioDevicePropertyTransportType:
        WRITE_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices:
        return WriteArray(related, 1, sizeof(AudioObjectID), inDataSize, outDataSize, outData);
    case kAudioDevicePropertyClockDomain:
        WRITE_VALUE(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive:
        WRITE_VALUE(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&gStateMutex);
        UInt32 running = gIOClients > 0;
        pthread_mutex_unlock(&gStateMutex);
        WRITE_VALUE(UInt32, running);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        WRITE_VALUE(UInt32, 1);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        WRITE_VALUE(UInt32, 0);
    case kAudioDevicePropertyLatency:
        WRITE_VALUE(UInt32, 0);
    case kAudioDevicePropertySafetyOffset:
        WRITE_VALUE(UInt32, 0);
    case kAudioDevicePropertyNominalSampleRate: {
        pthread_mutex_lock(&gStateMutex);
        Float64 rate = gSampleRate;
        pthread_mutex_unlock(&gStateMutex);
        WRITE_VALUE(Float64, rate);
    }
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange ranges[kSupportedRateCount];
        for (UInt32 i = 0; i < kSupportedRateCount; i++) {
            ranges[i].mMinimum = kSupportedRates[i];
            ranges[i].mMaximum = kSupportedRates[i];
        }
        return WriteArray(ranges, kSupportedRateCount, sizeof(AudioValueRange), inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyIsHidden:
        WRITE_VALUE(UInt32, 0);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        static const UInt32 channels[2] = { 1, 2 };
        if (outData != NULL && inDataSize < sizeof(channels)) return kAudioHardwareBadPropertySizeError;
        return WriteArray(channels, 2, sizeof(UInt32), inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyZeroTimeStampPeriod:
        WRITE_VALUE(UInt32, kRingFrames);
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    Boolean isInput = inObjectID == kObjectID_Stream_Input;

    switch (inAddress->mSelector) {
    case kAudioObjectPropertyBaseClass:
        WRITE_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        WRITE_VALUE(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner:
        WRITE_VALUE(AudioObjectID, kObjectID_Device);
    case kAudioObjectPropertyOwnedObjects:
        return WriteArray(NULL, 0, sizeof(AudioObjectID), inDataSize, outDataSize, outData);
    case kAudioStreamPropertyIsActive: {
        pthread_mutex_lock(&gStateMutex);
        UInt32 active = isInput ? gInputActive : gOutputActive;
        pthread_mutex_unlock(&gStateMutex);
        WRITE_VALUE(UInt32, active);
    }
    case kAudioStreamPropertyDirection:
        WRITE_VALUE(UInt32, isInput ? 1 : 0);
    case kAudioStreamPropertyTerminalType:
        WRITE_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel:
        WRITE_VALUE(UInt32, 1);
    case kAudioStreamPropertyLatency:
        WRITE_VALUE(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        pthread_mutex_lock(&gStateMutex);
        AudioStreamBasicDescription format = MakeFormat(gSampleRate);
        pthread_mutex_unlock(&gStateMutex);
        WRITE_VALUE(AudioStreamBasicDescription, format);
    }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription formats[kSupportedRateCount];
        for (UInt32 i = 0; i < kSupportedRateCount; i++) {
            formats[i].mFormat = MakeFormat(kSupportedRates[i]);
            formats[i].mSampleRateRange.mMinimum = kSupportedRates[i];
            formats[i].mSampleRateRange.mMaximum = kSupportedRates[i];
        }
        return WriteArray(formats, kSupportedRateCount, sizeof(AudioStreamRangedDescription), inDataSize, outDataSize, outData);
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus PropertyImpl(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                             UInt32 inQualifierDataSize, const void* inQualifierData,
                             UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (inObjectID) {
    case kObjectID_PlugIn:
        return PlugInProperty(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
    case kObjectID_Device:
        return DeviceProperty(inAddress, inDataSize, outDataSize, outData);
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
        return StreamProperty(inObjectID, inAddress, inDataSize, outDataSize, outData);
    default:
        return kAudioHardwareBadObjectError;
    }
}

static Boolean HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    UInt32 size = 0;
    return PropertyImpl(inObjectID, inAddress, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    if (inDriver != gDriverRef || inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;

    AudioObjectPropertySelector selector = inAddress->mSelector;
    switch (inObjectID) {
    case kObjectID_Device:
        *outIsSettable = selector == kAudioDevicePropertyNominalSampleRate;
        break;
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
        *outIsSettable = selector == kAudioStreamPropertyVirtualFormat
                      || selector == kAudioStreamPropertyPhysicalFormat
                      || selector == kAudioStreamPropertyIsActive;
        break;
    default:
        *outIsSettable = false;
        break;
    }
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    return PropertyImpl(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    return PropertyImpl(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
}

static OSStatus RequestSampleRate(Float64 rate) {
    if (!IsSupportedRate(rate)) return kAudioDeviceUnsupportedFormatError;
    pthread_mutex_lock(&gStateMutex);
    Boolean changed = rate != gSampleRate;
    pthread_mutex_unlock(&gStateMutex);
    if (changed && gHost != NULL) {
        return gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)rate, NULL);
    }
    return kAudioHardwareNoError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef || inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;

    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return RequestSampleRate(*(const Float64*)inData);
    }

    if (inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output) {
        switch (inAddress->mSelector) {
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription* format = inData;
            if (format->mFormatID != kAudioFormatLinearPCM
                || format->mChannelsPerFrame != kChannelCount
                || format->mBitsPerChannel != 32
                || (format->mFormatFlags & kAudioFormatFlagIsFloat) == 0) {
                return kAudioDeviceUnsupportedFormatError;
            }
            return RequestSampleRate(format->mSampleRate);
        }
        case kAudioStreamPropertyIsActive: {
            if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            if (inObjectID == kObjectID_Stream_Input) gInputActive = *(const UInt32*)inData != 0;
            else gOutputActive = *(const UInt32*)inData != 0;
            pthread_mutex_unlock(&gStateMutex);
            return kAudioHardwareNoError;
        }
        default:
            break;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOClients == 0) {
        gTimeStampCount = 0;
        gAnchorHostTime = mach_absolute_time();
        gWrittenUntil = 0;
        memset(gRing, 0, sizeof(gRing));
    }
    gIOClients++;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOClients > 0) gIOClients--;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kRingFrames;
    UInt64 nextPeriodTime = gAnchorHostTime + (UInt64)((Float64)(gTimeStampCount + 1) * ticksPerPeriod);
    if (nextPeriodTime <= now) gTimeStampCount++;
    *outSampleTime = (Float64)(gTimeStampCount * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimeStampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    *outWillDo = inOperationID == kAudioServerPlugInIOOperationReadInput
              || inOperationID == kAudioServerPlugInIOOperationWriteMix;
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL || inIOBufferFrameSize > kRingFrames) return kAudioHardwareNoError;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObjectID_Stream_Output) {
        // Il mix di tutte le app che suonano sul dispositivo: salvalo nel ring alla sua posizione temporale.
        Float64 sampleTime = floor(inIOCycleInfo->mOutputTime.mSampleTime);
        if (sampleTime < 0) return kAudioHardwareNoError;
        const Float32* source = ioMainBuffer;
        UInt32 offset = (UInt32)((UInt64)sampleTime % kRingFrames);
        UInt32 first = kRingFrames - offset;
        if (first > inIOBufferFrameSize) first = inIOBufferFrameSize;
        memcpy(&gRing[offset * kChannelCount], source, first * kBytesPerFrame);
        if (first < inIOBufferFrameSize) {
            memcpy(gRing, source + first * kChannelCount, (inIOBufferFrameSize - first) * kBytesPerFrame);
        }
        gWrittenUntil = sampleTime + inIOBufferFrameSize;
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStreamObjectID == kObjectID_Stream_Input) {
        // Restituisce ciò che è stato riprodotto; silenzio dove il ring non ha dati validi
        // (nessuna app in riproduzione, o dati più vecchi di un giro del ring).
        Float64 sampleTime = floor(inIOCycleInfo->mInputTime.mSampleTime);
        Float32* destination = ioMainBuffer;
        Float64 validStart = gWrittenUntil - kRingFrames;
        Float64 validEnd = gWrittenUntil;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; frame++) {
            Float64 time = sampleTime + frame;
            Float32* out = &destination[frame * kChannelCount];
            if (time >= 0 && time >= validStart && time < validEnd) {
                const Float32* in = &gRing[((UInt64)time % kRingFrames) * kChannelCount];
                out[0] = in[0];
                out[1] = in[1];
            } else {
                out[0] = 0;
                out[1] = 0;
            }
        }
    }
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}
