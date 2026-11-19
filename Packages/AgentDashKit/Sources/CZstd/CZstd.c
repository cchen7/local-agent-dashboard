#include "CZstd.h"

/* Compile the byte-for-byte upstream decoder once, in this translation unit.
 * Vendor is excluded from SwiftPM source discovery, not from this include. */
#include "Vendor/zstddeclib.c"

struct ADZSTD_Decoder {
    ZSTD_DCtx *context;
    size_t maximumWindowSize;
    unsigned char header[ZSTD_FRAMEHEADERSIZE_MAX];
    size_t headerSize;
    int readingHeader;
};

static ADZSTD_Status ADZSTD_status(size_t result)
{
    if (!ZSTD_isError(result)) return result == 0 ? ADZSTD_frameComplete : ADZSTD_more;
    switch (ZSTD_getErrorCode(result)) {
        case ZSTD_error_frameParameter_windowTooLarge: return ADZSTD_windowLimitExceeded;
        case ZSTD_error_dictionary_wrong:
        case ZSTD_error_dictionary_corrupted: return ADZSTD_dictionaryRequired;
        case ZSTD_error_memory_allocation: return ADZSTD_allocationFailed;
        default: return ADZSTD_corruptInput;
    }
}

ADZSTD_Decoder *ADZSTD_create(size_t maximumWindowSize)
{
    if (maximumWindowSize < 1024 || maximumWindowSize > ADZSTD_WINDOW_LIMIT) return NULL;
    ADZSTD_Decoder *decoder = (ADZSTD_Decoder *)calloc(1, sizeof(*decoder));
    if (decoder == NULL) return NULL;
    decoder->context = ZSTD_createDCtx();
    if (decoder->context == NULL ||
        ZSTD_isError(ZSTD_DCtx_setMaxWindowSize(decoder->context, maximumWindowSize))) {
        ADZSTD_destroy(decoder);
        return NULL;
    }
    decoder->maximumWindowSize = maximumWindowSize;
    decoder->readingHeader = 1;
    return decoder;
}

void ADZSTD_destroy(ADZSTD_Decoder *decoder)
{
    if (decoder == NULL) return;
    ZSTD_freeDCtx(decoder->context);
    free(decoder);
}

ADZSTD_Status ADZSTD_step(ADZSTD_Decoder *decoder,
                         const void *input, size_t inputSize, size_t *inputConsumed,
                         void *output, size_t outputCapacity, size_t *outputProduced)
{
    *inputConsumed = 0;
    *outputProduced = 0;
    if (decoder == NULL || output == NULL || outputCapacity == 0 ||
        outputCapacity > ADZSTD_OUTPUT_LIMIT || (input == NULL && inputSize != 0)) {
        return ADZSTD_corruptInput;
    }
    ZSTD_outBuffer destination = { output, outputCapacity, 0 };

    if (decoder->readingHeader) {
        ZSTD_FrameHeader frame;
        for (;;) {
            size_t needed = ZSTD_getFrameHeader(&frame, decoder->header, decoder->headerSize);
            if (ZSTD_isError(needed)) return ADZSTD_status(needed);
            if (needed == 0) break;
            if (needed > sizeof(decoder->header) || needed <= decoder->headerSize) {
                return ADZSTD_corruptInput;
            }
            size_t available = inputSize - *inputConsumed;
            size_t count = MIN(needed - decoder->headerSize, available);
            if (count == 0) return ADZSTD_more;
            memcpy(decoder->header + decoder->headerSize,
                   (const unsigned char *)input + *inputConsumed, count);
            decoder->headerSize += count;
            *inputConsumed += count;
        }

        /* Enforce policy before any payload, also for the upstream single-pass
         * shortcut that can bypass its streaming allocation/window check. */
        if (frame.dictID != 0) return ADZSTD_dictionaryRequired;
        if (frame.windowSize > decoder->maximumWindowSize) return ADZSTD_windowLimitExceeded;

        ZSTD_inBuffer header = { decoder->header, decoder->headerSize, 0 };
        size_t result = ZSTD_decompressStream(decoder->context, &destination, &header);
        if (ZSTD_isError(result)) return ADZSTD_status(result);
        if (header.pos != header.size) return ADZSTD_corruptInput;
        decoder->headerSize = 0;
        decoder->readingHeader = result == 0;
        if (result == 0) return ADZSTD_frameComplete; /* Empty skippable frame. */
        if (*inputConsumed == inputSize) return ADZSTD_more;
    }

    const void *remaining = inputSize == 0 ? input : (const unsigned char *)input + *inputConsumed;
    ZSTD_inBuffer source = { remaining, inputSize - *inputConsumed, 0 };
    size_t result = ZSTD_decompressStream(decoder->context, &destination, &source);
    *inputConsumed += source.pos;
    *outputProduced = destination.pos;
    if (result == 0) decoder->readingHeader = 1;
    return ADZSTD_status(result);
}
