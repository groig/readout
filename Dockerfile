# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#     E.g.: docker.io/hexpm/elixir:1.19.7-erlang-28.5.0.9-debian-trixie-20261123-slim
#   - https://hub.docker.com/_/debian/tags?name=trixie-20261123-slim - for the runner image
#     E.g.: docker.io/debian:trixie-20261123-slim
#
# Find builder and runner images on Docker Hub or on Hex's Build Server (Bob).
# We recommend using Bob's Web UI to find recent tags:
#
#   - https://bob.hex.pm/docker?repo=hexpm/elixir&os=debian&sort=elixir_version,erlang_version,os_version
#
# We suggest using the same Debian version for both the builder and runner images.
#
# We suggest Debian/Ubuntu instead of Alpine to avoid production compatibility issues
# (such as DNS resolution failures, and dynamically linked NIFs/precompiled binaries).
#
# For finding packages in Debian, search on https://packages.debian.org/.

# OTP 28.5.0.9 or later: earlier OTP 28 releases have a TLS 1.2 client
# certificate-validation flaw (matters for SMTP with STARTTLS). Keep the
# Debian snapshot recent too; the runner also applies pending security updates.
ARG ELIXIR_VERSION=1.19.7
ARG OTP_VERSION=28.5.0.9
ARG DEBIAN_VERSION=trixie-20261123-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

# Runtime: the Erlang release needs the first line. Readout adds poppler
# (pdfinfo, pdftoppm, pdftotext), cwebp, headless LibreOffice (Writer,
# Impress and Calc, no GUI) and the fonts documents commonly use, so converted Word and
# PowerPoint files look right: Carlito and Caladea stand in for Calibri and
# Cambria; Liberation for Arial, Times and Courier; DejaVu and Noto cover the rest.
RUN apt-get update \
  && apt-get upgrade -y --no-install-recommends \
  && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 locales ca-certificates tini curl \
    poppler-utils webp imagemagick fontconfig util-linux mount \
    libreoffice-writer-nogui libreoffice-impress-nogui libreoffice-calc-nogui \
    fonts-crosextra-carlito fonts-crosextra-caladea \
    fonts-liberation fonts-liberation2 fonts-dejavu-core fonts-noto-core \
  && rm -rf /var/lib/apt/lists/* \
  && fc-cache -f

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# A dedicated unprivileged user; files go to the /data volume.
RUN useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin readout \
  && mkdir -p /data/storage \
  && chown -R readout:readout /data

WORKDIR "/app"

ENV MIX_ENV="prod"
ENV STORAGE_PATH="/data/storage"
ENV PORT="4000"

# Only copy the final release from the build stage
COPY --from=builder --chown=readout:root /app/_build/${MIX_ENV}/rel/readout ./

COPY LICENSE /app/LICENSE

USER readout
VOLUME ["/data"]
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -fsS http://localhost:4000/healthz || exit 1

# tini reaps the LibreOffice and poppler child processes.
ENTRYPOINT ["/usr/bin/tini", "--"]

# Runs migrations, then starts the server (see rel/overlays/bin/server).
CMD ["/app/bin/server"]
