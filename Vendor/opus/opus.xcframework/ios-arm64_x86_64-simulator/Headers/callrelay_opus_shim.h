/* Fixed-signature CTL wrappers for libopus.
 *
 * opus_encoder_ctl is variadic in C, which Swift cannot import. These
 * shims expose the handful of encoder CTLs the app uses as plain
 * functions; compiled into the vendored libopus.a for both gateway
 * (CGo could call the variadic form directly) and the iOS XCFramework.
 *
 * SPDX-License-Identifier: BSD-3-Clause (same as libopus; this file is
 * trivial glue provided under the same license for convenience). */
#ifndef CALLRELAY_OPUS_SHIM_H
#define CALLRELAY_OPUS_SHIM_H

#include "opus.h"

#ifdef __cplusplus
extern "C" {
#endif

int callrelay_opus_enc_set_bitrate(OpusEncoder *st, opus_int32 value);
int callrelay_opus_enc_set_loss_perc(OpusEncoder *st, opus_int32 value);
int callrelay_opus_enc_set_fec(OpusEncoder *st, opus_int32 value);
int callrelay_opus_enc_set_dtx(OpusEncoder *st, opus_int32 value);
int callrelay_opus_enc_set_complexity(OpusEncoder *st, opus_int32 value);

#ifdef __cplusplus
}
#endif

#endif /* CALLRELAY_OPUS_SHIM_H */
