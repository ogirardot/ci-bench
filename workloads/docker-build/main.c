/*
 * main.c — the tiny C program the docker-build workload compiles.
 *
 * The BUILD is the benchmark (multi-stage, network fetch of build-base, gcc
 * invocation, final image assembly). The program itself just does a
 * deterministic FNV-1a pass so the binary is non-trivial and its output is
 * stable across platforms: ci-bench-docker-a56ee6092483
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

#define ROUNDS 2000000u
#define SEED_LEN 64

static uint64_t fnv1a(uint64_t h, const unsigned char *data, size_t len) {
    for (size_t i = 0; i < len; i++) {
        h ^= data[i];
        h *= 1099511628211ULL; /* FNV prime */
    }
    return h;
}

int main(void) {
    unsigned char seed[SEED_LEN];
    for (size_t i = 0; i < SEED_LEN; i++)
        seed[i] = (unsigned char)(i * 31 + 7);

    uint64_t h = 1469598103934665603ULL; /* FNV offset basis */
    for (uint32_t r = 0; r < ROUNDS; r++) {
        seed[0] = (unsigned char)(r & 0xff);
        seed[1] = (unsigned char)((r >> 8) & 0xff);
        h = fnv1a(h, seed, SEED_LEN);
    }

    /* Expected: stable for the fixed seed/rounds above; printed so a runner
     * log shows the binary actually executed. */
    printf("ci-bench-docker-%012llx\n", (unsigned long long)(h & 0xffffffffffffULL));
    return 0;
}
