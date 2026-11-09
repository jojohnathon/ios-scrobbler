#ifndef SCROBBLER_FINGERPRINT_H
#define SCROBBLER_FINGERPRINT_H

#include <stddef.h>
#include <stdint.h>

typedef struct FingerprintBytes {
    uint8_t *data;
    size_t length;
} FingerprintBytes;

// Input is exactly twelve seconds of mono signed 16-bit PCM at 16 kHz.
// A successful result owns a raw Shazam signature. Release it with the function below.
FingerprintBytes scrobbler_fingerprint(const int16_t *samples, size_t sample_count);
void scrobbler_free_fingerprint(FingerprintBytes bytes);

#endif
