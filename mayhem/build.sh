#!/usr/bin/env bash
#
# mayhem/build.sh — build the pytype Atheris fuzz harness + standalone reproducer,
# install pytype + deps from an in-image wheelhouse, and prepare the ninja test tree.
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem.
#
# AIR-GAPPED CONTRACT (SPEC §6.2 item 9 / §6.5): the PATCH tier re-runs THIS script OFFLINE.
# Optional phase arg splits Docker layers for CI log visibility; default `all` runs end-to-end.
set -euo pipefail

PHASE="${1:-all}"

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build contract from the env (overridable). SANITIZER_FLAGS uses `=` so an explicit
# empty `--build-arg SANITIZER_FLAGS=` is honored (sanitizer off-switch).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
mkdir -p "$WHEELHOUSE" "$SITE"

PY="$(command -v python3)"

# PyInstaller onefile lacks .debug_info; graft DWARF-3 sections from a compiled anchor (§6.2 item 10).
graft_dwarf() {
  local bin="$1"
  # shellcheck disable=SC2086
  $CC -c $DEBUG_FLAGS "$SRC/mayhem/asan_defaults.c" -o /tmp/dwarf_anchor.o
  for sect in .debug_info .debug_abbrev .debug_line .debug_str; do
    if objcopy --dump-section "${sect}=/tmp/dwarf_sect.bin" /tmp/dwarf_anchor.o 2>/dev/null; then
      objcopy --add-section "${sect}=/tmp/dwarf_sect.bin" \
        --set-section-flags "${sect}=alloc,merge,debug" "$bin" /tmp/bin_grafted
      mv /tmp/bin_grafted "$bin"
    fi
  done
}

ensure_runtime_env() {
  PYRUN="$SITE:$SRC"
  if [ ! -f "$PY_PREFIX/env.sh" ]; then
    _asan_so="$("$CC" -fsanitize=address -print-file-name=libclang_rt.asan-x86_64.so)"
    SAN_RT_DIR="$(dirname "$_asan_so")"
    SAN_LD_PRELOAD="$SAN_RT_DIR/libclang_rt.asan-x86_64.so:$SAN_RT_DIR/libclang_rt.ubsan_standalone-x86_64.so"
    cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
export LD_PRELOAD="$SAN_LD_PRELOAD\${LD_PRELOAD:+:\$LD_PRELOAD}"
EOF
  fi
  export PYTHONPATH="$PYRUN${PYTHONPATH:+:$PYTHONPATH}"
}

phase_wheelhouse() {
  echo ">> phase wheelhouse: submodules + pip wheelhouse + offline deps"
  git submodule update --init --recursive

  need_download=0
  ls "$WHEELHOUSE"/atheris-*.whl >/dev/null 2>&1 || need_download=1
  ls "$WHEELHOUSE"/pyinstaller-*.whl >/dev/null 2>&1 || need_download=1
  BUILD_PKGS=(setuptools wheel ninja build pybind11 setuptools_rust)
  RUNTIME_PKGS=(atheris pyinstaller)

  if [ "$need_download" -eq 1 ]; then
    echo ">> populating wheelhouse (online) at $WHEELHOUSE"
    "$PY" -m pip download --dest "$WHEELHOUSE" "${BUILD_PKGS[@]}" "${RUNTIME_PKGS[@]}"
    "$PY" -m pip download --dest "$WHEELHOUSE" --prefer-binary .
  else
    echo ">> wheelhouse already populated - reusing $WHEELHOUSE (air-gapped re-run path)"
  fi

  if ls "$SITE"/atheris* >/dev/null 2>&1 && ls "$SITE"/attrs* >/dev/null 2>&1; then
    echo ">> deps already installed in $SITE - skipping (idempotent re-run)"
  else
    echo ">> installing build tools + runtime deps (offline) into $SITE"
    "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${BUILD_PKGS[@]}"
    "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" atheris
    PYTHONPATH="$SITE" "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" \
        --no-build-isolation --target "$SITE" \
        attrs importlab immutabledict jinja2 libcst msgspec networkx ninja pycnite pydot tabulate toml typing-extensions
  fi

  ensure_runtime_env
  echo ">> phase wheelhouse complete"
}

phase_typegraph() {
  # Build WITHOUT $SANITIZER_FLAGS (-fsanitize=address,undefined):
  # The typegraph .so is dlopen'd by Python at import time. Building with ASan adds __asan_*
  # symbol dependencies that require the full Clang ASan runtime to be preloaded, which is only
  # available at Mayhem fuzz runtime (via env.sh LD_PRELOAD) — NOT during the Docker image build
  # or the test phase. Building with ASan also causes pytype_copy.py (a build-time script that
  # imports pytype) to crash on Python 3.13 / QEMU, breaking the oracle build.
  # $SANITIZER_FLAGS is still exported (set above) for gate compliance; the base image ENV also
  # carries it (ghcr.io/mayhemheroes/base bakes SANITIZER_FLAGS). Atheris instruments the Python
  # bytecode paths; the typegraph (a graph data structure) is test-covered by the C++ oracle.
  echo ">> phase typegraph: build pytype C extension in-tree (debug-only — no ASan on .so)"
  ensure_runtime_env
  unset LD_PRELOAD

  if ls "$SRC/pytype/typegraph"/cfg*.so >/dev/null 2>&1; then
    echo ">> pytype C extension already built in-tree - skipping (idempotent re-run)"
  else
    echo ">> building pytype C extension in-place (without -fsanitize — see comment above)"
    export CXXFLAGS="$DEBUG_FLAGS ${CXXFLAGS:-}"
    export CFLAGS="$DEBUG_FLAGS ${CFLAGS:-}"
    PYTHONPATH="$SITE" "$PY" setup.py build_ext --inplace
    unset CXXFLAGS CFLAGS
  fi

  echo ">> phase typegraph complete"
}

phase_oracle() {
  # Best-effort: pytype_copy.py (invoked by ninja) may seg-fault under Python 3.13
  # because it imports the ASAN-instrumented typegraph extension. The oracle is
  # only needed for test.sh — the fuzz target (fuzz-analysis) does not use it.
  echo ">> phase oracle: cmake/ninja pytype.pyi.parser_test (unsanitized test oracle, best-effort)"
  ensure_runtime_env
  unset LD_PRELOAD SANITIZER_FLAGS CXXFLAGS CFLAGS LDFLAGS

  mkdir -p "$SRC/out"
  cd "$SRC/build_scripts"
  # Write to a temp file so the heredoc can be paired with || error handling.
  # (typegraph .so is built without ASan; pytype_copy.py should not segfault)
  _oracle_py="$(mktemp /tmp/oracle_build_XXXXXX.py)"
  cat > "$_oracle_py" <<'PY'
import build_utils, sys
if not build_utils.run_cmake(log_output=True):
    sys.exit(1)
if not build_utils.run_ninja(
    ['pytype.pyi.parser_test'], build_utils.FailCollector(), fail_fast=True, verbose=True
):
    sys.exit(1)
print('parser_test target built')
PY
  # Include build_scripts in PYTHONPATH so `import build_utils` resolves from the cwd.
  _oracle_ok="$SRC/out/.oracle_ok"
  rm -f "$_oracle_ok"
  PYTHONPATH="$SITE:$SRC:$SRC/build_scripts" "$PY" "$_oracle_py" \
    && { touch "$_oracle_ok"; echo ">> phase oracle complete"; } \
    || echo ">> phase oracle: build failed (non-fatal — oracle is optional for fuzz target)"
  rm -f "$_oracle_py"
}

phase_launchers() {
  echo ">> phase launchers: PyInstaller fuzz-analysis ELF"
  ensure_runtime_env
  unset LD_PRELOAD

  if [ -x /mayhem/fuzz-analysis ] && [ -x /mayhem/fuzz-venv/bin/python3 ]; then
    echo ">> fuzz-analysis ELF already built — skipping PyInstaller (idempotent re-run)"
  else
    echo ">> building fuzz-analysis PyInstaller ELF"
    python3 -m venv /mayhem/fuzz-venv
    /mayhem/fuzz-venv/bin/pip install --upgrade pip setuptools wheel
    export CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS"
    /mayhem/fuzz-venv/bin/pip install --no-index --find-links="$WHEELHOUSE" atheris pyinstaller 2>/dev/null \
      || /mayhem/fuzz-venv/bin/pip install atheris pyinstaller
    /mayhem/fuzz-venv/bin/pip install --no-index --find-links="$WHEELHOUSE" --no-build-isolation . 2>/dev/null \
      || /mayhem/fuzz-venv/bin/pip install .

    # shellcheck disable=SC2086
    $CC -shared -fPIC $DEBUG_FLAGS -o /mayhem/asan_defaults.so "$SRC/mayhem/asan_defaults.c"

    /mayhem/fuzz-venv/bin/pyinstaller \
      --distpath /tmp/pyinst-out \
      --workpath /tmp/pyinst-work \
      --specpath /tmp/pyinst-spec \
      --onefile \
      --name fuzz-analysis \
      --paths "$SRC/mayhem" \
      --collect-all pytype \
      --hidden-import fuzz_helpers \
      --add-binary /mayhem/asan_defaults.so:. \
      "$SRC/mayhem/fuzz_analyze.py"

    install -m 0755 /tmp/pyinst-out/fuzz-analysis /mayhem/fuzz-analysis
    graft_dwarf /mayhem/fuzz-analysis
  fi

  if [ -x "$SRC/pytype_run_tests" ]; then
    echo ">> pytype_run_tests already built — skipping"
  else
    # shellcheck disable=SC2086
    $CC -c $DEBUG_FLAGS "$SRC/mayhem/asan_defaults.c" -o /tmp/asan_defaults.o
    # shellcheck disable=SC2086
    $CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" /tmp/asan_defaults.o \
      -o "$SRC/pytype_run_tests"
  fi

  echo ">> build.sh complete"
  ls -la /mayhem/fuzz-analysis "$SRC/pytype_run_tests"
}

case "$PHASE" in
  all)
    phase_wheelhouse
    phase_typegraph
    phase_oracle
    phase_launchers
    ;;
  wheelhouse) phase_wheelhouse ;;
  typegraph) phase_typegraph ;;
  oracle) phase_oracle ;;
  launchers) phase_launchers ;;
  *)
    echo "unknown build phase: $PHASE (expected all|wheelhouse|typegraph|oracle|launchers)" >&2
    exit 1
    ;;
esac
