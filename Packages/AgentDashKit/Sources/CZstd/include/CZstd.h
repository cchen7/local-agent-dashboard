#ifndef AD_CZSTD_H
#define AD_CZSTD_H

#include <stddef.h>

enum {
    ADZSTD_WINDOW_LIMIT = 8 * 1024 * 1024,
    ADZSTD_OUTPUT_LIMIT = 128 * 1024
};

typedef struct ADZSTD_Decoder ADZSTD_Decoder;

typedef enum {
    ADZSTD_more = 0,
    ADZSTD_frameComplete,
    ADZSTD_corruptInput,
    ADZSTD_windowLimitExceeded,
    ADZSTD_dictionaryRequired,
    ADZSTD_allocationFailed
} ADZSTD_Status;

/* No dictionary-loading or file APIs. A NULL result means allocation failed
 * or maximumWindowSize was outside [1024, ADZSTD_WINDOW_LIMIT]. */
ADZSTD_Decoder *ADZSTD_create(size_t maximumWindowSize);
void ADZSTD_destroy(ADZSTD_Decoder *decoder);

/* One streaming step, at most one frame boundary. Input is borrowed only for
 * this call. The caller must preserve unconsumed input and drain full output.
 * Output capacity must be in [1, ADZSTD_OUTPUT_LIMIT]. Never reuse after error. */
ADZSTD_Status ADZSTD_step(ADZSTD_Decoder *decoder,
                         const void *input, size_t inputSize, size_t *inputConsumed,
                         void *output, size_t outputCapacity, size_t *outputProduced);

#endif
