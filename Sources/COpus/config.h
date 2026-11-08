/* The configuration of libopus 1.6.1 in this package: float build, no DNN features, NEON intrinsics presumed on arm64. */
#ifndef COPUS_CONFIG_H
#define COPUS_CONFIG_H
#define PACKAGE_VERSION "1.6.1"
#define VAR_ARRAYS 1
#define HAVE_ALLOCA_H 1
#define HAVE_LRINT 1
#define HAVE_LRINTF 1
#define DISABLE_DEBUG_FLOAT 1
#define ENABLE_HARDENING 1
#if defined(__aarch64__)
#define OPUS_ARM_MAY_HAVE_NEON 1
#define OPUS_ARM_MAY_HAVE_NEON_INTR 1
#define OPUS_ARM_PRESUME_NEON 1
#define OPUS_ARM_PRESUME_NEON_INTR 1
#endif
#endif
