# Multi-stage Dockerfile for building TruffleRuby native image from source
# and creating a minimal runtime base image for Ruby applications
#
# STAGES:
#   - builder:      Builds TruffleRuby native image from source (intermediate)
#   - runtime:      Base image with C extension compilation support
#   - runtime-slim: Minimal base image (no C extension support)
#
# MEMORY REQUIREMENTS:
#   The native image build requires at least 10GB of memory available to Docker.
#   On Docker Desktop (macOS/Windows), you must increase the memory limit:
#     - Docker Desktop > Settings > Resources > Memory: set to 12GB or more
#   On Linux with Docker Engine, memory is shared with host (ensure sufficient RAM).
#
# USAGE:
#
# Build the runtime image (with C extension support):
#   docker build -f tool/dockerfiles/build-native.dockerfile \
#                --target runtime -t truffleruby-native:runtime .
#
# Build the slim runtime image (no C extension support):
#   docker build -f tool/dockerfiles/build-native.dockerfile \
#                --target runtime-slim -t truffleruby-native:slim .
#
# Build with custom memory settings (for systems with more RAM):
#   docker build -f tool/dockerfiles/build-native.dockerfile \
#                --build-arg NATIVE_IMAGE_XMX=12g \
#                --build-arg NATIVE_IMAGE_PARALLELISM=4 \
#                --target runtime -t truffleruby-native:runtime .
#
# Run an interactive Ruby shell:
#   docker run -it truffleruby-native:runtime
#
# Use as base image for your application:
#   FROM truffleruby-native:runtime
#   WORKDIR /app
#   COPY Gemfile Gemfile.lock ./
#   RUN bundle install
#   COPY . .
#   CMD ["ruby", "app.rb"]
#
# NOTE:
#   - The build takes significant time (30-90 minutes depending on resources)
#   - GitHub Actions CI builds this successfully on runners with ~7GB RAM using
#     constrained settings (7GB heap, 1 thread) which takes ~90 minutes

# =============================================================================
# Stage 1: Builder - Builds TruffleRuby native image from source
# =============================================================================
# Use buildpack-deps:jammy which has gcc, g++, make, git, curl, wget, perl,
# ca-certificates, libssl-dev, libz-dev pre-installed
FROM buildpack-deps:jammy AS builder

# Native image build configuration
# These can be overridden with --build-arg for systems with more/less memory
ARG NATIVE_IMAGE_XMX=8g
ARG NATIVE_IMAGE_PARALLELISM=2

ENV DEBIAN_FRONTEND=noninteractive

# Install only the additional dependencies not in buildpack-deps
# - ruby: system ruby for jt tool
# - python3: required for mx build tool
# - ninja-build: for native builds
# - cmake: for building Sulong (GraalVM's LLVM support)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ruby \
    python3 \
    ninja-build \
    cmake \
    && rm -rf /var/lib/apt/lists/*

# Install ninja_syntax Python module (required by mx for native builds)
# Download directly to avoid installing pip and its many dependencies
RUN mkdir -p /usr/lib/python3/dist-packages && \
    wget -q -O /usr/lib/python3/dist-packages/ninja_syntax.py \
    https://raw.githubusercontent.com/ninja-build/ninja/master/misc/ninja_syntax.py

# Set up working directory
WORKDIR /truffleruby

# Copy the TruffleRuby source code
COPY . .

# Set up jt in PATH
ENV PATH="/truffleruby/bin:${PATH}"

# Clone graal repository with correct version
RUN jt sforceimports

# Install JVMCI JDK and store the path
# The jt install jvmci command outputs multiple lines; the last line is the JAVA_HOME path
# Use tail -1 to extract just the path
RUN JAVA_HOME_PATH=$(jt install jvmci | tail -1) && \
    echo "JAVA_HOME=$JAVA_HOME_PATH" > /tmp/java_home.env && \
    echo "Captured JAVA_HOME: $JAVA_HOME_PATH"

# Build TruffleRuby native image
# This takes significant time (30-90 minutes depending on resources)
# Memory/parallelism settings controlled by build args (see top of file)
RUN export JAVA_HOME=$(cat /tmp/java_home.env | cut -d= -f2) && \
    echo "Using JAVA_HOME: $JAVA_HOME" && \
    echo "Native image settings: Xmx=${NATIVE_IMAGE_XMX}, parallelism=${NATIVE_IMAGE_PARALLELISM}" && \
    jt build --env native \
        --extra-image-builder-argument=rubyvm:-J-Xmx${NATIVE_IMAGE_XMX} \
        --extra-image-builder-argument=rubyvm:--parallelism=${NATIVE_IMAGE_PARALLELISM}

# Get the ruby-home path and create the distribution
RUN RUBY_HOME=$(jt -u native ruby-home) && \
    mv "$RUBY_HOME" /truffleruby-dist

# =============================================================================
# Stage 2: Runtime - Minimal base image for running TruffleRuby applications
# =============================================================================
FROM debian:stable-slim AS runtime

ENV LANG=C.UTF-8

# GEM_HOME for global gem installation
ENV GEM_HOME=/usr/local/bundle
ENV BUNDLE_SILENCE_ROOT_WARNING=1 \
    BUNDLE_APP_CONFIG="$GEM_HOME"
ENV PATH=$GEM_HOME/bin:/usr/local/bin:$PATH

# Install runtime dependencies
# - make, gcc, g++: for building C and C++ extensions
# - libz-dev: for zlib extension
# - ca-certificates: for SSL/TLS
RUN apt-get update && apt-get install -y --no-install-recommends \
    make \
    gcc \
    g++ \
    ca-certificates \
    libz-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy TruffleRuby from builder stage
COPY --from=builder /truffleruby-dist /usr/local

# Run post-install hook to set up TruffleRuby
RUN /usr/local/lib/truffle/post_install_hook.sh

# Verify installation
RUN ruby --version && \
    gem --version && \
    bundle --version

# Set up gem directory with proper permissions
RUN mkdir -p "$GEM_HOME" && chmod 777 "$GEM_HOME"

# Default command
CMD [ "irb" ]

# =============================================================================
# Stage 3: Runtime slim - Even more minimal (no C extension compilation support)
# =============================================================================
FROM debian:stable-slim AS runtime-slim

ENV LANG=C.UTF-8

# GEM_HOME for global gem installation
ENV GEM_HOME=/usr/local/bundle
ENV BUNDLE_SILENCE_ROOT_WARNING=1 \
    BUNDLE_APP_CONFIG="$GEM_HOME"
ENV PATH=$GEM_HOME/bin:/usr/local/bin:$PATH

# Minimal runtime dependencies (no build tools)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libz1 \
    && rm -rf /var/lib/apt/lists/*

# Copy TruffleRuby from builder stage
COPY --from=builder /truffleruby-dist /usr/local

# Run post-install hook
RUN /usr/local/lib/truffle/post_install_hook.sh

# Verify installation
RUN ruby --version && \
    gem --version && \
    bundle --version

# Set up gem directory with proper permissions
RUN mkdir -p "$GEM_HOME" && chmod 777 "$GEM_HOME"

# Default command
CMD [ "irb" ]
