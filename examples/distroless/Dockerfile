# syntax=docker/dockerfile:1

# Build from the repository root:
#
#   docker build -f examples/distroless/Dockerfile \
#     -t rubycc-distroless-example .
#   docker run --rm rubycc-distroless-example
#
# An upstream distroless image does not contain a Ruby runtime, so this sample
# starts from the official Ruby image and makes the final stage distroless in
# posture: compilation happens in the builder, while the runtime has Ruby,
# compiled gems, and their shared-library dependencies only.

FROM ruby:4.0-slim AS build

ARG JSON_VERSION=2.21.1
ARG MSGPACK_VERSION=1.8.3
ARG SQLITE3_VERSION=2.9.5
ARG PG_VERSION=1.6.3
ARG DEB_MULTIARCH=x86_64-linux-gnu

# Keep rubycc separate from the application gems. It is needed by the build
# stage, but it should not be copied into the runtime image.
# External database libraries need their -L flags, but their C headers are
# supplied through explicit gem options below, not libc defaults.
ENV RUBYCC_HOME=/opt/rubycc \
    GEM_HOME=/opt/gems \
    GEM_PATH=/opt/rubycc:/opt/gems \
    RUBYCC=1 \
    RUBYCC_HERMETIC_HEADERS=1 \
    PKG_CONFIG_ALLOW_SYSTEM_LIBS=1

# sqlite3.pc advertises /usr/include. Keep only this external header in a
# separate directory so hermetic mode still excludes libc headers.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      libsqlite3-dev \
      libpq-dev \
      pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/external/include \
    && cp /usr/include/sqlite3.h /opt/external/include/sqlite3.h

WORKDIR /src

# Copy only the files needed to build the rubycc gem. This keeps application
# source and development-only files out of the builder input.
#
# The file list has to match rubycc.gemspec's `files` exactly: `gem build`
# rejects a specification naming a file that is not there ("[...] are not
# files", a Gem::InvalidSpecificationException, not a warning). That is how
# this sample broke -- CHANGELOG.md joined the gemspec during release
# preparation and this list did not follow.
COPY lib ./lib
COPY include ./include
COPY exe ./exe
COPY data ./data
COPY rubycc.gemspec LICENSE.txt NOTICE README.md CHANGELOG.md ./

RUN set -eux; \
    mkdir -p "$RUBYCC_HOME" "$GEM_HOME"; \
    gem build rubycc.gemspec --output /tmp/rubycc.gem; \
    GEM_HOME="$RUBYCC_HOME" GEM_PATH="$RUBYCC_HOME" \
      gem install --local /tmp/rubycc.gem --no-document; \
    gem install --platform ruby --no-document \
      json -v "$JSON_VERSION"; \
    gem install --platform ruby --no-document \
      msgpack -v "$MSGPACK_VERSION"; \
    gem install --platform ruby --no-document \
      sqlite3 -v "$SQLITE3_VERSION" -- \
        --enable-system-libraries \
        --with-sqlite3-include=/opt/external/include \
        --with-sqlite3-lib=/usr/lib/$DEB_MULTIARCH; \
    gem install --platform ruby --no-document \
      pg -v "$PG_VERSION" -- \
        --with-pg-include=/usr/include/postgresql \
        --with-pg-lib=/usr/lib/$DEB_MULTIARCH

FROM ruby:4.0-slim AS runtime

# sqlite3 and pg are linked against these runtime libraries. Their -dev
# packages, libc headers, and all build tools stay in the build stage.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      libsqlite3-0 \
      libpq5 \
    && rm -rf /var/lib/apt/lists/*

ENV GEM_HOME=/opt/gems \
    GEM_PATH=/opt/gems

COPY --from=build /opt/gems /opt/gems
COPY examples/distroless/smoke.rb /app/smoke.rb

# Official Ruby images retain Ruby's development headers. Remove them along
# with the shell after all image setup is complete; CMD uses exec form and
# therefore does not need /bin/sh at runtime.
RUN rm -rf /usr/include /usr/local/include/ruby* \
    && rm -f /bin/sh /usr/bin/sh /bin/dash /bin/bash /usr/bin/bash

USER 65532:65532
CMD ["ruby", "/app/smoke.rb"]
