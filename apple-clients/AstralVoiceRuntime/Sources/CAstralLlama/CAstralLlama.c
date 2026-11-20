// Implements the CAstralLlama surface: model and encoder loading, prompt evaluation and one-token-at-a-time sampling on top of llama.cpp and libmtmd.
// Swift drives the decode loop through avr_next so cancellation can stop it between tokens, and the abort flag stops a prompt evaluation in flight.
#include "CAstralLlama.h"

#include <ggml-backend.h>
#include <llama.h>
#include <mtmd-helper.h>
#include <mtmd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

struct avr_cancel {
    atomic_int raised;
};

struct avr_model {
    struct llama_model *weights;
    struct llama_context *context;
    struct mtmd_context *encoder;
    const struct llama_vocab *vocab;
    struct llama_sampler *sampler;
    avr_cancel *cancel;
    llama_pos position;
    int32_t used;
    int32_t context_tokens;
    int32_t batch_tokens;
};

static pthread_once_t backend_once = PTHREAD_ONCE_INIT;

static void discard_log(enum ggml_log_level level, const char *text, void *user) {
    (void)level;
    (void)text;
    (void)user;
}

static void start_backend(void) {
    if (getenv("ASTRAL_VOICE_RUNTIME_LOG") == NULL) {
        llama_log_set(discard_log, NULL);
        mtmd_log_set(discard_log, NULL);
    }
    llama_backend_init();
}

static bool is_cancelled(const avr_cancel *cancel) {
    return cancel != NULL && atomic_load_explicit(&((avr_cancel *)cancel)->raised, memory_order_relaxed) != 0;
}

static bool abort_requested(void *data) {
    return is_cancelled((const avr_cancel *)data);
}

avr_cancel *avr_cancel_new(void) {
    avr_cancel *cancel = calloc(1, sizeof(avr_cancel));
    return cancel;
}

void avr_cancel_free(avr_cancel *cancel) {
    free(cancel);
}

void avr_cancel_raise(avr_cancel *cancel) {
    if (cancel != NULL) {
        atomic_store_explicit(&cancel->raised, 1, memory_order_relaxed);
    }
}

avr_model *avr_model_load(const char *model_path, const char *encoder_path, avr_options options, avr_status *status) {
    pthread_once(&backend_once, start_backend);
    *status = AVR_OK;
    if (model_path == NULL || options.context_tokens <= 0 || options.batch_tokens <= 0 || options.threads <= 0) {
        *status = AVR_INVALID_ARGUMENT;
        return NULL;
    }
    avr_model *model = calloc(1, sizeof(avr_model));
    if (model == NULL) {
        *status = AVR_MODEL_LOAD_FAILED;
        return NULL;
    }
    ggml_backend_dev_t no_devices[1] = {NULL};
    struct llama_model_params model_params = llama_model_default_params();
    if (options.cpu_only) {
        model_params.devices = no_devices;
        model_params.n_gpu_layers = 0;
    } else {
        model_params.n_gpu_layers = 99;
    }
    model->weights = llama_model_load_from_file(model_path, model_params);
    if (model->weights == NULL) {
        *status = AVR_MODEL_LOAD_FAILED;
        goto fail;
    }
    model->vocab = llama_model_get_vocab(model->weights);
    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = (uint32_t)options.context_tokens;
    context_params.n_batch = (uint32_t)options.batch_tokens;
    context_params.n_ubatch = (uint32_t)(options.batch_tokens < 256 ? options.batch_tokens : 256);
    context_params.n_threads = options.threads;
    context_params.n_threads_batch = options.threads;
    model->context = llama_init_from_model(model->weights, context_params);
    if (model->context == NULL) {
        *status = AVR_CONTEXT_FAILED;
        goto fail;
    }
    model->context_tokens = (int32_t)llama_n_ctx(model->context);
    model->batch_tokens = options.batch_tokens;
    if (encoder_path != NULL) {
        struct mtmd_context_params encoder_params = mtmd_context_params_default();
        encoder_params.use_gpu = !options.cpu_only;
        encoder_params.n_threads = options.threads;
        encoder_params.warmup = false;
        model->encoder = mtmd_init_from_file(encoder_path, model->weights, encoder_params);
        if (model->encoder == NULL) {
            *status = AVR_ENCODER_LOAD_FAILED;
            goto fail;
        }
        if (!mtmd_support_audio(model->encoder)) {
            *status = AVR_ENCODER_WITHOUT_AUDIO;
            goto fail;
        }
    }
    return model;
fail:
    avr_model_free(model);
    return NULL;
}

void avr_model_free(avr_model *model) {
    if (model == NULL) {
        return;
    }
    if (model->sampler != NULL) {
        llama_sampler_free(model->sampler);
    }
    if (model->encoder != NULL) {
        mtmd_free(model->encoder);
    }
    if (model->context != NULL) {
        llama_free(model->context);
    }
    if (model->weights != NULL) {
        llama_model_free(model->weights);
    }
    free(model);
}

int32_t avr_model_context_tokens(const avr_model *model) {
    return model->context_tokens;
}

int32_t avr_model_audio_sample_rate(const avr_model *model) {
    return model->encoder == NULL ? 0 : mtmd_get_audio_sample_rate(model->encoder);
}

char *avr_model_chat_prompt(const avr_model *model, const char *const *roles, const char *const *contents, size_t count, avr_status *status) {
    *status = AVR_OK;
    const char *template_text = llama_model_chat_template(model->weights, NULL);
    if (template_text == NULL) {
        *status = AVR_NO_CHAT_TEMPLATE;
        return NULL;
    }
    struct llama_chat_message *messages = calloc(count > 0 ? count : 1, sizeof(struct llama_chat_message));
    if (messages == NULL) {
        *status = AVR_INVALID_ARGUMENT;
        return NULL;
    }
    size_t characters = 0;
    for (size_t index = 0; index < count; index++) {
        messages[index].role = roles[index];
        messages[index].content = contents[index];
        characters += strlen(roles[index]) + strlen(contents[index]);
    }
    int32_t capacity = (int32_t)(2 * characters + 256);
    char *buffer = malloc((size_t)capacity);
    int32_t needed = buffer == NULL ? -1 : llama_chat_apply_template(template_text, messages, count, true, buffer, capacity);
    if (needed > capacity) {
        char *larger = realloc(buffer, (size_t)needed + 1);
        if (larger == NULL) {
            needed = -1;
        } else {
            buffer = larger;
            needed = llama_chat_apply_template(template_text, messages, count, true, buffer, needed + 1);
        }
    }
    free(messages);
    if (needed < 0) {
        free(buffer);
        *status = AVR_NO_CHAT_TEMPLATE;
        return NULL;
    }
    buffer[needed] = '\0';
    return buffer;
}

void avr_string_free(char *string) {
    free(string);
}

static avr_status prepare(avr_model *model, avr_sampling sampling, avr_cancel *cancel) {
    if (model->sampler != NULL) {
        llama_sampler_free(model->sampler);
        model->sampler = NULL;
    }
    model->cancel = cancel;
    model->position = 0;
    model->used = 0;
    llama_memory_clear(llama_get_memory(model->context), true);
    llama_set_abort_callback(model->context, abort_requested, cancel);
    struct llama_sampler_chain_params chain_params = llama_sampler_chain_default_params();
    model->sampler = llama_sampler_chain_init(chain_params);
    if (model->sampler == NULL) {
        return AVR_CONTEXT_FAILED;
    }
    if (sampling.temperature <= 0.0f) {
        llama_sampler_chain_add(model->sampler, llama_sampler_init_greedy());
    } else {
        if (sampling.top_k > 0) {
            llama_sampler_chain_add(model->sampler, llama_sampler_init_top_k(sampling.top_k));
        }
        llama_sampler_chain_add(model->sampler, llama_sampler_init_temp(sampling.temperature));
        llama_sampler_chain_add(model->sampler, llama_sampler_init_dist(sampling.seed));
    }
    return AVR_OK;
}

static avr_status decode_tokens(avr_model *model, const llama_token *tokens, int32_t count, bool logits_last) {
    struct llama_batch_ext *batch = llama_batch_ext_init(model->context);
    if (batch == NULL) {
        return AVR_DECODE_FAILED;
    }
    avr_status status = AVR_OK;
    int32_t index = 0;
    while (index < count) {
        llama_batch_ext_clear(batch);
        int32_t slot = -1;
        int32_t added = 0;
        while (index < count && added < model->batch_tokens) {
            slot = llama_batch_ext_add_token(batch, 0, tokens[index]);
            if (slot < 0) {
                status = AVR_DECODE_FAILED;
                goto done;
            }
            llama_pos position = model->position + added;
            llama_batch_ext_set_pos(batch, slot, &position);
            index++;
            added++;
        }
        if (logits_last && index == count) {
            llama_batch_ext_set_output_logits(batch, slot, true);
        }
        int32_t result = llama_process(model->context, LLAMA_PROCESS_TYPE_DECODE, batch);
        if (result != 0) {
            status = is_cancelled(model->cancel) ? AVR_CANCELLED : AVR_DECODE_FAILED;
            goto done;
        }
        model->position += added;
        model->used += added;
    }
done:
    llama_batch_ext_free(batch);
    return status;
}

avr_status avr_begin_text(avr_model *model, const char *prompt, avr_sampling sampling, avr_cancel *cancel, int32_t *prompt_tokens) {
    avr_status status = prepare(model, sampling, cancel);
    if (status != AVR_OK) {
        return status;
    }
    size_t length = strlen(prompt);
    int32_t capacity = (int32_t)length + 64;
    llama_token *tokens = malloc(sizeof(llama_token) * (size_t)capacity);
    if (tokens == NULL) {
        return AVR_TOKENIZE_FAILED;
    }
    int32_t count = llama_tokenize(model->vocab, prompt, (int32_t)length, tokens, capacity, true, true);
    if (count < 0) {
        free(tokens);
        return AVR_TOKENIZE_FAILED;
    }
    *prompt_tokens = count;
    if (count == 0) {
        free(tokens);
        return AVR_TOKENIZE_FAILED;
    }
    if (count >= model->context_tokens) {
        free(tokens);
        return AVR_PROMPT_TOO_LONG;
    }
    status = decode_tokens(model, tokens, count, true);
    free(tokens);
    return status;
}

avr_status avr_begin_audio(avr_model *model, const char *prompt, const float *samples, size_t sample_count, avr_sampling sampling, avr_cancel *cancel, int32_t *prompt_tokens) {
    if (model->encoder == NULL) {
        return AVR_ENCODER_WITHOUT_AUDIO;
    }
    avr_status status = prepare(model, sampling, cancel);
    if (status != AVR_OK) {
        return status;
    }
    struct mtmd_bitmap *bitmap = mtmd_bitmap_init_from_audio(sample_count, samples);
    struct mtmd_input_chunks *chunks = mtmd_input_chunks_init();
    if (bitmap == NULL || chunks == NULL) {
        status = AVR_TOKENIZE_FAILED;
        goto done;
    }
    const struct mtmd_bitmap *bitmaps[1] = {bitmap};
    struct mtmd_input_text text = {prompt, strlen(prompt), true, true};
    if (mtmd_tokenize(model->encoder, chunks, &text, bitmaps, 1) != 0) {
        status = AVR_TOKENIZE_FAILED;
        goto done;
    }
    size_t total = 0;
    for (size_t index = 0; index < mtmd_input_chunks_size(chunks); index++) {
        total += mtmd_input_chunk_get_n_tokens(mtmd_input_chunks_get(chunks, index));
    }
    *prompt_tokens = (int32_t)total;
    if (total >= (size_t)model->context_tokens) {
        status = AVR_PROMPT_TOO_LONG;
        goto done;
    }
    llama_pos past = 0;
    int32_t result = mtmd_helper_eval_chunks(model->encoder, model->context, chunks, 0, 0, model->batch_tokens, true, &past);
    if (result != 0) {
        status = is_cancelled(cancel) ? AVR_CANCELLED : AVR_ENCODE_FAILED;
        goto done;
    }
    model->position = past;
    model->used = (int32_t)total;
done:
    if (chunks != NULL) {
        mtmd_input_chunks_free(chunks);
    }
    if (bitmap != NULL) {
        mtmd_bitmap_free(bitmap);
    }
    return status;
}

avr_status avr_next(avr_model *model, char *piece, int32_t capacity, int32_t *length) {
    *length = 0;
    if (is_cancelled(model->cancel)) {
        return AVR_CANCELLED;
    }
    if (model->used >= model->context_tokens) {
        return AVR_CONTEXT_FULL;
    }
    llama_token token = llama_sampler_sample(model->sampler, model->context, -1);
    if (token == LLAMA_TOKEN_NULL) {
        return AVR_DECODE_FAILED;
    }
    if (llama_vocab_is_eog(model->vocab, token)) {
        return AVR_END;
    }
    int32_t written = llama_token_to_piece(model->vocab, token, piece, capacity, 0, false);
    if (written < 0) {
        return AVR_DECODE_FAILED;
    }
    avr_status status = decode_tokens(model, &token, 1, true);
    if (status != AVR_OK) {
        return status;
    }
    *length = written;
    return AVR_TOKEN;
}
