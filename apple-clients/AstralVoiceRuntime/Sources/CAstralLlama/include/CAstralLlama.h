// C surface over llama.cpp and libmtmd that exposes only opaque handles, plain integers and C strings to Swift.
// Sources/AstralVoiceRuntime wraps it in actors; the implementation lives in CAstralLlama.c and links the xcframework built by Scripts/build-voice-runtime.sh.
#ifndef CASTRAL_LLAMA_H
#define CASTRAL_LLAMA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    AVR_OK = 0,
    AVR_TOKEN,
    AVR_END,
    AVR_CONTEXT_FULL,
    AVR_CANCELLED,
    AVR_INVALID_ARGUMENT,
    AVR_MODEL_LOAD_FAILED,
    AVR_ENCODER_LOAD_FAILED,
    AVR_ENCODER_WITHOUT_AUDIO,
    AVR_CONTEXT_FAILED,
    AVR_TOKENIZE_FAILED,
    AVR_PROMPT_TOO_LONG,
    AVR_ENCODE_FAILED,
    AVR_DECODE_FAILED,
    AVR_NO_CHAT_TEMPLATE,
} avr_status;

typedef struct {
    bool cpu_only;
    int32_t context_tokens;
    int32_t batch_tokens;
    int32_t threads;
} avr_options;

typedef struct {
    float temperature;
    int32_t top_k;
    uint32_t seed;
} avr_sampling;

typedef struct avr_model avr_model;
typedef struct avr_cancel avr_cancel;

avr_cancel *avr_cancel_new(void);
void avr_cancel_free(avr_cancel *cancel);
void avr_cancel_raise(avr_cancel *cancel);

avr_model *avr_model_load(const char *model_path, const char *encoder_path, avr_options options, avr_status *status);
void avr_model_free(avr_model *model);
int32_t avr_model_context_tokens(const avr_model *model);
int32_t avr_model_audio_sample_rate(const avr_model *model);

char *avr_model_chat_prompt(const avr_model *model, const char *const *roles, const char *const *contents, size_t count, avr_status *status);
void avr_string_free(char *string);

/* Both begin calls reset the context, so one model serves one run at a time. */
avr_status avr_begin_text(avr_model *model, const char *prompt, avr_sampling sampling, avr_cancel *cancel, int32_t *prompt_tokens);
avr_status avr_begin_audio(avr_model *model, const char *prompt, const float *samples, size_t sample_count, avr_sampling sampling, avr_cancel *cancel, int32_t *prompt_tokens);

avr_status avr_next(avr_model *model, char *piece, int32_t capacity, int32_t *length);

#ifdef __cplusplus
}
#endif

#endif
