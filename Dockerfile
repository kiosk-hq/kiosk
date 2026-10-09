# One image for every demo in this repository. The demos resolve the kiosk
# gems through `path: "../kiosk-<gem>"`, so the build context is the whole
# repository; each demo's compose.yaml picks the working directory.
#
# The image carries the tools demo code runs: python3 with numpy (registering
# an assistant solves an Equihash toll with the bundled solve.py), and curl and
# jq for the shell walkthroughs. Compose provides Postgres.
#
# The Ruby version is a build argument, and `bin/check-demo-copies` holds it to
# a version this repository's CI actually runs and to the floor the gemspecs
# declare, so it cannot drift into naming a Ruby nothing here is tested on.
ARG RUBY_VERSION=4.0.1
FROM ruby:${RUBY_VERSION}-slim

# python3-numpy for the Equihash solver (the Debian package, so no pip and no
# wheel build); curl and jq for the shell walkthroughs; the rest is what the
# `pg` and `psych` native extensions need to compile.
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y \
      build-essential \
      ca-certificates \
      curl \
      git \
      jq \
      libpq-dev \
      libyaml-dev \
      python3 \
      python3-numpy \
 && rm -rf /var/lib/apt/lists/*

ENV BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3 \
    LANG=C.UTF-8

WORKDIR /kiosk
COPY . /kiosk

# One bundle per demo. The loop is derived from what is in the tree rather than
# from a list of demo names, so a demo added to this repository is installed
# here without editing this file.
# The `tmp`, `log` and `storage` directories are excluded from the build
# context (see .dockerignore), so they are recreated here rather than relied on:
# Rails makes most of them for itself, and a demo that assumes one exists should
# not be the thing that discovers this.
RUN set -eux; \
    for demo in /kiosk/kiosk-demo-*; do \
      test -f "$demo/Gemfile" || continue; \
      mkdir -p "$demo/tmp/pids" "$demo/log" "$demo/storage"; \
      (cd "$demo" && bundle install); \
    done

# Every demo starts the same way: `db:reset` drops, recreates, loads the schema
# and seeds the compose project's own Postgres, then the app serves on $PORT.
# Each demo's compose.yaml supplies the working directory and the port.
CMD ["sh", "-c", "bin/rails db:reset && exec bin/rails server -b 0.0.0.0 -p ${PORT:?compose must set PORT}"]
