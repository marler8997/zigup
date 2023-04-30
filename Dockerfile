FROM docker.io/library/alpine:latest

# Update the system
RUN apk update && apk upgrade

# Initialize build tools directory
RUN mkdir -p /tools
WORKDIR /tools

# Install Zig
RUN apk add --no-cache git curl tar xz
ARG ZIG_VERSION=0.11.0-dev.1507+6f13a725a
RUN curl -sSfL \
      https://ziglang.org/builds/zig-linux-x86_64-"$ZIG_VERSION".tar.xz \
      -o zig.tar.xz && \
    tar -xf zig.tar.xz && \
    mv zig-linux-x86_64-"$ZIG_VERSION" zig
ENV PATH="/tools/zig:$PATH"

# Build zigup
ARG ZIGUP_TARGET=x86_64-linux
ARG ZIGUP_BUILD_FLAGS=-Drelease-safe
COPY . /zigup
WORKDIR /zigup
RUN zig build -Dfetch -Dtarget="$ZIGUP_TARGET" $ZIGUP_BUILD_FLAGS
ENV PATH="/zigup/zig-out/bin:$PATH"

ENTRYPOINT ["/zigup/zig-out/bin/zigup"]
