# The container path for every demo in this repository — ONE image, eight apps.
#
# WHY ONE IMAGE RATHER THAN EIGHT. The demos are eight standalone Rails apps
# whose Gemfiles resolve the kiosk gems through `path: "../kiosk-<gem>"`, so a
# build context that contains only one demo cannot install its dependencies:
# the context has to be this repository. Once it is, per-demo images buy
# nothing and cost something real — getgrocery's `demo:agecheck` and skooti's
# `demo:kyc`/`demo:redteam` boot the KYC broker in `kiosk-demo-prove`, so an
# image carrying one demo's bundle could not run three of the headline tasks.
# This image bundles every demo; each demo's compose.yaml picks the working
# directory. The gem sets overlap almost entirely, so the eight installs share
# nearly all of their work.
#
# WHAT THE IMAGE CARRIES vs WHAT COMPOSE PROVIDES. The image carries what the
# demo CODE shells out to and cannot supply for itself: the `psql` client, pinned to the major the tracked `structure.sql` was dumped by (every
# `demo:setup` runs `psql -d postgres` directly, not only through ActiveRecord),
# python3 with numpy (every task that registers an assistant pays an Equihash
# toll and solves it with the bundled `solve.py`), and `curl` + `jq` (the three
# demos whose walkthrough is a shell tour drive it with them). Compose provides
# what is a SERVER rather than a tool: Postgres, on its own volume, on the
# compose project's own network. That split is what makes the container path
# need no host database and no `CREATE ROLE` grant — the demo talks to a
# Postgres that belongs to the demo, as its superuser.
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
      gnupg \
      jq \
      libpq-dev \
      libyaml-dev \
      python3 \
      python3-numpy \
 && rm -rf /var/lib/apt/lists/*

# The psql client comes from PGDG rather than from the base image, pinned to the
# SAME major the compose database runs, for the reason ci.yml gives where it does
# the same thing: every demo's `db/structure.sql` is tracked in PG17 dump format
# and `demo:setup` loads it with `psql`. A client from whatever major the base
# image happens to carry is the one variable that turns a green build into a
# schema load that fails on a stranger's machine and not on ours.
RUN set -eux; \
    . /etc/os-release; \
    echo "deb https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      > /etc/apt/trusted.gpg.d/pgdg.asc; \
    apt-get update -qq; \
    apt-get install --no-install-recommends -y postgresql-client-17; \
    rm -rf /var/lib/apt/lists/*

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

# The default command is the same for every demo because the setup task is:
# `demo:setup` drops, recreates, loads the schema and seeds — against the
# compose project's own Postgres — and then the app serves on $PORT. Each
# demo's compose.yaml supplies the working directory and the port.
#
# The bind address is 0.0.0.0 because the only thing that can reach it is the
# port compose publishes to the host; the flow drivers the demo tasks boot for
# themselves keep binding 127.0.0.1, inside this container, as they do on a host.
CMD ["sh", "-c", "bin/rails demo:setup && exec bin/rails server -b 0.0.0.0 -p ${PORT:?compose must set PORT}"]
