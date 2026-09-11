# docker-build workload — multi-stage build against a digest-pinned base.
#
# The base is pinned to the exact alpine:3.20 digest rickub itself pins for its
# own CI images (images/firecracker/rootfs/Dockerfile in the rickub monorepo),
# i.e. a digest known to be stable and public. CAVEAT (documented in README):
# `apk add` inside the builder still floats with the Alpine mirror at run time;
# a truly bit-frozen build would vendored-package the toolchain, which would
# remove the network component this workload deliberately measures.

# syntax=docker/dockerfile:1
ARG ALPINE_IMAGE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

# --- builder: fetch toolchain, compile --------------------------------------
FROM ${ALPINE_IMAGE} AS builder
RUN apk add --no-cache build-base
WORKDIR /src
COPY main.c .
RUN cc -O2 -static -o ci-bench-docker main.c

# --- final: tiny image, just the static binary ------------------------------
FROM ${ALPINE_IMAGE}
WORKDIR /
COPY --from=builder /src/ci-bench-docker /usr/local/bin/ci-bench-docker
# Expected output: ci-bench-docker-a56ee6092483
CMD ["/usr/local/bin/ci-bench-docker"]
