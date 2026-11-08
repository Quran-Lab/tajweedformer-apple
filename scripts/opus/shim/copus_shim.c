#include "copus_shim.h"
int copus_encoder_set(OpusEncoder *st, int request, opus_int32 value) { return opus_encoder_ctl(st, request, value); }
int copus_encoder_get(OpusEncoder *st, int request, opus_int32 *value) { return opus_encoder_ctl(st, request, value); }
int copus_decoder_set(OpusDecoder *st, int request, opus_int32 value) { return opus_decoder_ctl(st, request, value); }
int copus_decoder_get(OpusDecoder *st, int request, opus_int32 *value) { return opus_decoder_ctl(st, request, value); }
int copus_encoder_reset(OpusEncoder *st) { return opus_encoder_ctl(st, OPUS_RESET_STATE); }
