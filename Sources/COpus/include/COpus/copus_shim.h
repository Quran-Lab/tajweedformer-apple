/* Non-variadic wrappers for opus_encoder_ctl/opus_decoder_ctl, which Swift cannot call directly. */
#ifndef COPUS_SHIM_H
#define COPUS_SHIM_H
#include "opus.h"
#ifdef __cplusplus
extern "C" {
#endif
/* A SET request with one opus_int32 argument, e.g. copus_encoder_set(e, OPUS_SET_BITRATE_REQUEST, 96000). */
int copus_encoder_set(OpusEncoder *st, int request, opus_int32 value);
/* A GET request with one opus_int32 out argument, e.g. copus_encoder_get(e, OPUS_GET_LOOKAHEAD_REQUEST, &n). */
int copus_encoder_get(OpusEncoder *st, int request, opus_int32 *value);
int copus_decoder_set(OpusDecoder *st, int request, opus_int32 value);
int copus_decoder_get(OpusDecoder *st, int request, opus_int32 *value);
/* OPUS_RESET_STATE */
int copus_encoder_reset(OpusEncoder *st);
#ifdef __cplusplus
}
#endif
#endif
