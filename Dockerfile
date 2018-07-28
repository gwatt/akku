# -*- mode: dockerfile; coding: utf-8 -*-
FROM weinholt/chezscheme AS build
RUN apt-get update && apt-get -y --no-install-recommends install \
       ca-certificates \
       curl \
       git \
       xz-utils \
  && rm -rf /var/lib/apt/lists/*

COPY . /tmp
WORKDIR /tmp
RUN set -uxe; \
    test -d .git && git clean -d -d -x -f; \
    . .akku/bin/activate; \
    mkdir -p ~/.akku/share/keys.d; \
    cp akku-archive-*.gpg ~/.akku/share/keys.d; \
    akku.sps update; \
    private/build.chezscheme.sps; \
    tar -xvaf akku-*+*-linux.tar.xz; \
    cd akku-*+*-linux; \
    ./install.sh; \
    ~/bin/akku

# No Scheme implementation pre-installed.
FROM debian:buster
RUN apt-get update && apt-get -y --no-install-recommends install \
       ca-certificates \
       curl \
       git \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /root/.akku /root/.akku
ENV PATH="/root/.akku/bin:${PATH}"
RUN akku version
