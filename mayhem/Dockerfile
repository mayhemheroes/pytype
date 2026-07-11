# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — PYTHON target (atheris / libFuzzer). Builds ON TOP of the org
# C/C++ base (ghcr.io/mayhemheroes/base). The base ships CPython + pip + clang; this adds an
# in-image Python wheelhouse + site dir under /opt/toolchains/python and runs mayhem/build.sh.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t pytype-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

# NOTE: COMMIT and REPO_URL are declared late (just before LABEL) so they don't invalidate
# the build cache for the expensive wheelhouse/typegraph/oracle/launchers layers.
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

ENV PY_PREFIX=/opt/toolchains/python \
    PYTHONPATH=/opt/toolchains/python/site:/mayhem \
    PYTHONDONTWRITEBYTECODE=1

# apt as root WITHOUT LD_PRELOAD — preloading ASan/UBSan on apt-get update/install spins/hangs.
USER root
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && apt-get install -yq --no-install-recommends \
      bison cmake flex g++ python3-dev python3-venv python-is-python3 \
    && rm -rf /var/lib/apt/lists/*
RUN install -d -o 2000 -g 2000 /opt/toolchains/python
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Split build.sh into layers so CI logs show progress; `bash mayhem/build.sh` (no arg) still
# runs all phases for air-gapped PATCH re-runs. LD_PRELOAD is only in env.sh for fuzz runtime.
RUN bash mayhem/build.sh wheelhouse
RUN bash mayhem/build.sh typegraph
RUN bash mayhem/build.sh oracle
RUN bash mayhem/build.sh launchers

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

ARG COMMIT
ARG REPO_URL
LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
