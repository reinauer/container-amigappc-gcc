#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ADTOOLS_REPO_URL="https://github.com/sba1/adtools.git"
ADTOOLS_GCC_BRANCH="8"
ADTOOLS_BINUTILS_BRANCH="2.23.2"
SDK_VERSION="54.16"
SDK_URL="${SDK_URL:-}"
SDK_ARCHIVE=""
PREFIX="/opt/amiga-ppc"
WORKDIR="${SCRIPT_DIR}/.mac-build"
JOBS=""
INSTALL_BREW=1
BUILD_LHA=1
INSTALL_PYTHON_VENV=1
REUSE_SOURCE=0
HOST_CC="${CC:-}"
HOST_CXX="${CXX:-}"
MAKE_BIN=""
MAKE_SHELL=""
HOST_SHIM_DIR=""

BREW_PACKAGES=(
  bash
  wget
  make
  gmp
  mpfr
  libmpc
  flex
  gettext
  gnu-sed
  texinfo
  autoconf
  automake
  bison
  gcc
  libtool
  pkg-config
  python
)

usage() {
  cat <<'EOF'
Usage: ./build_mac.sh [options]

Build ADTools ppc-amigaos-gcc on macOS.

Defaults:
  ADTools GCC branch:      8
  ADTools binutils branch: 2.23.2
  SDK version:             54.16
  install prefix:          /opt/amiga-ppc
  source workdir:          ./.mac-build

Options:
  --prefix DIR             Install prefix (default: /opt/amiga-ppc)
  --workdir DIR            Build workspace (default: ./.mac-build)
  --jobs N                 Parallel make jobs (default: macOS CPU count)
  --repo URL               ADTools repository URL
  --gcc-branch BRANCH      ADTools GCC branch to checkout
  --binutils-branch BRANCH ADTools binutils branch to checkout
  --sdk-version VERSION    AmigaOS SDK version passed to ADTools
  --sdk-url URL            Override ADTools SDK download URL
  --sdk-archive PATH       Use a local SDK .lha archive
  --cc PATH_OR_NAME        Host GNU C compiler
  --cxx PATH_OR_NAME       Host GNU C++ compiler
  --skip-brew              Do not install Homebrew formulae
  --skip-lha-build         Use an existing lha from PATH
  --skip-python-venv       Do not create a local Python venv with Mako
  --reuse-source           Reuse existing source checkout
  -h, --help               Show this help

Examples:
  ./build_mac.sh
  ./build_mac.sh --prefix "$HOME/opt/amiga-ppc"
  ./build_mac.sh --sdk-archive "$HOME/Downloads/SDK_54.16.lha"
  ./build_mac.sh --gcc-branch 8 --binutils-branch 2.23.2
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

prepend_unique_path() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *) PATH="${dir}:${PATH}" ;;
    esac
  fi
}

append_unique_path() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *) PATH="${PATH}:${dir}" ;;
    esac
  fi
}

detect_jobs() {
  if [[ -n "$JOBS" ]]; then
    return
  fi

  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || printf '4')"
  if [[ -z "$JOBS" || "$JOBS" -lt 1 ]]; then
    JOBS=4
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix)
        [[ $# -ge 2 ]] || die "--prefix requires a value"
        PREFIX="${2%/}"
        shift 2
        ;;
      --workdir)
        [[ $# -ge 2 ]] || die "--workdir requires a value"
        WORKDIR="${2%/}"
        shift 2
        ;;
      --jobs)
        [[ $# -ge 2 ]] || die "--jobs requires a value"
        JOBS="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a value"
        ADTOOLS_REPO_URL="$2"
        shift 2
        ;;
      --gcc-branch)
        [[ $# -ge 2 ]] || die "--gcc-branch requires a value"
        ADTOOLS_GCC_BRANCH="$2"
        shift 2
        ;;
      --binutils-branch)
        [[ $# -ge 2 ]] || die "--binutils-branch requires a value"
        ADTOOLS_BINUTILS_BRANCH="$2"
        shift 2
        ;;
      --sdk-version)
        [[ $# -ge 2 ]] || die "--sdk-version requires a value"
        SDK_VERSION="$2"
        shift 2
        ;;
      --sdk-url)
        [[ $# -ge 2 ]] || die "--sdk-url requires a value"
        SDK_URL="$2"
        shift 2
        ;;
      --sdk-archive)
        [[ $# -ge 2 ]] || die "--sdk-archive requires a value"
        SDK_ARCHIVE="$2"
        shift 2
        ;;
      --cc)
        [[ $# -ge 2 ]] || die "--cc requires a value"
        HOST_CC="$2"
        shift 2
        ;;
      --cxx)
        [[ $# -ge 2 ]] || die "--cxx requires a value"
        HOST_CXX="$2"
        shift 2
        ;;
      --skip-brew)
        INSTALL_BREW=0
        shift
        ;;
      --skip-lha-build)
        BUILD_LHA=0
        shift
        ;;
      --skip-python-venv)
        INSTALL_PYTHON_VENV=0
        shift
        ;;
      --reuse-source)
        REUSE_SOURCE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

brew_prefix() {
  command -v brew >/dev/null 2>&1 || return 0
  brew --prefix "$1" 2>/dev/null || true
}

ensure_brew() {
  if [[ "$INSTALL_BREW" -eq 0 ]]; then
    log "Skipping Homebrew package installation"
    return
  fi

  command -v brew >/dev/null 2>&1 || \
    die "Homebrew is required. Install it from https://brew.sh/ first."

  local missing=()
  local package
  for package in "${BREW_PACKAGES[@]}"; do
    if ! brew list --formula "$package" >/dev/null 2>&1; then
      missing+=("$package")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing Homebrew packages: ${missing[*]}"
    brew install "${missing[@]}"
  else
    log "Homebrew packages already installed"
  fi
}

configure_macos_tools() {
  local brew_root bash_prefix bison_prefix flex_prefix gettext_prefix
  local gnu_sed_prefix make_prefix texinfo_prefix gcc_prefix gmp_prefix
  local mpfr_prefix mpc_prefix

  if command -v brew >/dev/null 2>&1; then
    brew_root="$(brew --prefix)"
  else
    brew_root=""
  fi

  bash_prefix="$(brew_prefix bash)"
  bison_prefix="$(brew_prefix bison)"
  flex_prefix="$(brew_prefix flex)"
  gettext_prefix="$(brew_prefix gettext)"
  gnu_sed_prefix="$(brew_prefix gnu-sed)"
  make_prefix="$(brew_prefix make)"
  texinfo_prefix="$(brew_prefix texinfo)"
  gcc_prefix="$(brew_prefix gcc)"
  gmp_prefix="$(brew_prefix gmp)"
  mpfr_prefix="$(brew_prefix mpfr)"
  mpc_prefix="$(brew_prefix libmpc)"

  prepend_unique_path "${make_prefix}/libexec/gnubin"
  prepend_unique_path "${gnu_sed_prefix}/libexec/gnubin"
  prepend_unique_path "${bison_prefix}/bin"
  prepend_unique_path "${flex_prefix}/bin"
  prepend_unique_path "${gettext_prefix}/bin"
  prepend_unique_path "${texinfo_prefix}/bin"
  prepend_unique_path "${gcc_prefix}/bin"
  prepend_unique_path "${brew_root}/bin"
  append_unique_path "${brew_root}/sbin"
  export PATH

  export CPPFLAGS="${CPPFLAGS:-}"
  export LDFLAGS="${LDFLAGS:-}"
  export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
  add_brew_flags "$gmp_prefix"
  add_brew_flags "$mpfr_prefix"
  add_brew_flags "$mpc_prefix"

  if [[ -n "$gettext_prefix" ]]; then
    export ACLOCAL_PATH="${gettext_prefix}/share/aclocal${ACLOCAL_PATH:+:${ACLOCAL_PATH}}"
  fi

  if [[ -z "$HOST_CC" ]]; then
    HOST_CC="$(find_host_compiler gcc)"
  fi

  if [[ -z "$HOST_CXX" ]]; then
    HOST_CXX="$(find_host_compiler g++)"
  fi

  verify_host_compiler "$HOST_CC" "C" "--cc"
  verify_host_compiler "$HOST_CXX" "C++" "--cxx"
  log "Using host compilers: CC=${HOST_CC} CXX=${HOST_CXX}"

  if command -v gmake >/dev/null 2>&1; then
    MAKE_BIN="$(command -v gmake)"
  else
    MAKE_BIN="$(command -v make)"
  fi
  [[ -n "$MAKE_BIN" ]] || die "make/gmake not found"

  if [[ -n "$bash_prefix" && -x "${bash_prefix}/bin/bash" ]]; then
    MAKE_SHELL="${bash_prefix}/bin/bash"
  elif [[ -n "$brew_root" && -x "${brew_root}/bin/bash" ]]; then
    MAKE_SHELL="${brew_root}/bin/bash"
  elif [[ -x /bin/bash ]]; then
    MAKE_SHELL="/bin/bash"
  else
    die "bash not found"
  fi
  export MAKE_SHELL

  command -v git >/dev/null 2>&1 || die "git not found"
  command -v wget >/dev/null 2>&1 || die "wget not found"
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  command -v autoreconf >/dev/null 2>&1 || die "autoreconf not found"
  command -v makeinfo >/dev/null 2>&1 || die "makeinfo not found"
  command -v flex >/dev/null 2>&1 || die "flex not found"
  command -v bison >/dev/null 2>&1 || die "bison not found"
}

find_host_compiler() {
  local base="$1"
  local candidate option

  if [[ "$base" == "gcc" ]]; then
    option="--cc"
  else
    option="--cxx"
  fi

  for candidate in "${base}-15" "${base}-16" \
      "${base}-14" "${base}-13" "${base}-12" "$base"; do
    if command -v "$candidate" >/dev/null 2>&1 &&
        is_gnu_compiler "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  die "no GNU ${base} compiler found; install Homebrew gcc or pass ${option}"
}

is_gnu_compiler() {
  local compiler="$1"
  local first_line

  first_line="$("$compiler" --version 2>/dev/null | head -n 1 || true)"
  [[ "$first_line" == *"GCC"* ||
     "$first_line" == *"Free Software Foundation"* ||
     "$first_line" == *"gcc"* ]]
}

verify_host_compiler() {
  local compiler="$1"
  local label="$2"
  local option="$3"

  command -v "$compiler" >/dev/null 2>&1 || \
    die "${label} compiler not found: ${compiler}"
  is_gnu_compiler "$compiler" || \
    die "${label} compiler is not GNU GCC: ${compiler}; pass ${option}"
}

add_brew_flags() {
  local prefix="$1"
  if [[ -n "$prefix" && -d "$prefix" ]]; then
    export CPPFLAGS="-I${prefix}/include ${CPPFLAGS}"
    export LDFLAGS="-L${prefix}/lib ${LDFLAGS}"
    if [[ -d "${prefix}/lib/pkgconfig" ]]; then
      export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    fi
  fi
}

install_host_shims() {
  local cc_path cxx_path

  cc_path="$(command -v "$HOST_CC")"
  cxx_path="$(command -v "$HOST_CXX")"
  HOST_SHIM_DIR="${WORKDIR}/host-tools"
  mkdir -p "$HOST_SHIM_DIR"
  ln -sf "$cc_path" "${HOST_SHIM_DIR}/gcc"
  ln -sf "$cxx_path" "${HOST_SHIM_DIR}/g++"
  prepend_unique_path "$HOST_SHIM_DIR"
  export PATH
}

ensure_python_env() {
  if [[ "$INSTALL_PYTHON_VENV" -eq 0 ]]; then
    log "Skipping Python venv"
    return
  fi

  local venv="${WORKDIR}/venv"
  log "Installing Python helpers into ${venv}"
  mkdir -p "$WORKDIR"
  python3 -m venv "$venv"
  "${venv}/bin/python" -m pip install -U pip
  "${venv}/bin/python" -m pip install -U Mako
  prepend_unique_path "${venv}/bin"
  export PATH
}

ensure_lha() {
  if [[ "$BUILD_LHA" -eq 0 ]]; then
    command -v lha >/dev/null 2>&1 || die "lha not found in PATH"
    log "Using existing lha: $(command -v lha)"
    return
  fi

  local src="${WORKDIR}/lha-src"
  local prefix="${WORKDIR}/lha-install"

  log "Building lha into ${prefix}"
  mkdir -p "$WORKDIR"
  if [[ ! -d "${src}/.git" ]]; then
    git clone --depth 1 https://github.com/jca02266/lha.git "$src"
  fi

  (
    cd "$src"
    autoreconf -vfi
    ./configure --prefix="$prefix"
    "$MAKE_BIN" -j "$JOBS"
    "$MAKE_BIN" install
  )

  prepend_unique_path "${prefix}/bin"
  export PATH
  command -v lha >/dev/null 2>&1 || die "built lha was not found"
}

ensure_prefix_writable() {
  local prefix="$1"

  if [[ -d "$prefix" && -w "$prefix" ]]; then
    return
  fi

  log "Preparing writable prefix ${prefix}"
  if mkdir -p "$prefix" 2>/dev/null; then
    :
  else
    sudo mkdir -p "$prefix"
  fi

  if [[ ! -w "$prefix" ]]; then
    sudo chown -R "$(id -u):$(id -g)" "$prefix"
  fi

  [[ -w "$prefix" ]] || die "prefix is not writable: ${prefix}"
}

safe_remove_source() {
  local src="$1"

  [[ -n "$src" ]] || die "empty source path"
  [[ "$src" != "/" ]] || die "refusing to remove /"
  [[ "$src" == "${WORKDIR}/"* ]] || \
    die "refusing to remove source outside workdir: ${src}"

  if [[ -d "$src" ]]; then
    rm -rf "$src"
  fi
}

prepare_source() {
  local src="$1"

  if [[ "$REUSE_SOURCE" -eq 0 ]]; then
    safe_remove_source "$src"
  fi

  if [[ ! -d "${src}/.git" ]]; then
    log "Cloning ADTools"
    mkdir -p "$(dirname "$src")"
    git clone --depth 1 "$ADTOOLS_REPO_URL" "$src"
  else
    log "Reusing source tree ${src}"
  fi

  (
    cd "$src"
    git submodule update --init --recursive gild
    patch_adtools_source_urls "$src"
    reset_managed_repo binutils/repo
    reset_managed_repo gcc/repo
    bin/gild checkout binutils "$ADTOOLS_BINUTILS_BRANCH"
    bin/gild checkout gcc "$ADTOOLS_GCC_BRANCH"
  )

  patch_binutils_makefile "$src"
  patch_gcc_apple_silicon_host "$src"
  patch_gcc_darwin_pch_alignment "$src"
  patch_gcc_makefile "$src"
  patch_native_makefile "$src"
  stage_sdk_archive "$src"
}

reset_managed_repo() {
  local repo="$1"

  if [[ -d "${repo}/.git" ]]; then
    git -C "$repo" reset --hard >/dev/null
  fi
}

patch_adtools_source_urls() {
  local src="$1"

  # The historical bminor GitHub mirror used by ADTools is gone. Use the
  # canonical Sourceware mirror so gild can still fetch the old binutils tag.
  printf '%s\n' https://sourceware.org/git/binutils-gdb.git > \
    "${src}/binutils/repo.url"
}

patch_binutils_makefile() {
  local src="$1"
  local makefile="${src}/binutils-build/Makefile"

  [[ -f "$makefile" ]] || die "missing ${makefile}"
  python3 - "$makefile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
for index, line in enumerate(lines):
    if "--enable-plugins" in line:
        indent = line.split("--", 1)[0]
        wanted = [
            f"{indent}--disable-nls \\\n",
            f"{indent}--disable-werror \\\n",
        ]
        window = "".join(lines[index + 1:index + 8])
        insert = [
            item for item in wanted
            if item.strip().split()[0] not in window
        ]
        if insert:
            lines[index + 1:index + 1] = insert
            path.write_text("".join(lines))
        break
PY
}

patch_gcc_apple_silicon_host() {
  local src="$1"
  local config_host="${src}/gcc/repo/gcc/config.host"

  [[ -f "$config_host" ]] || die "missing ${config_host}"
  python3 - "$config_host" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
insert = """  aarch64*-*-darwin* | arm*-*-darwin*)
    out_host_hook_obj="${out_host_hook_obj} host-i386-darwin.o"
    host_xmake_file="${host_xmake_file} i386/x-darwin"
    ;;
"""
anchor = """  i[34567]86-*-darwin* | x86_64-*-darwin*)
    out_host_hook_obj="${out_host_hook_obj} host-i386-darwin.o"
    host_xmake_file="${host_xmake_file} i386/x-darwin"
    ;;
"""
if insert not in text:
    if anchor not in text:
        raise SystemExit("darwin host hook anchor not found")
    path.write_text(text.replace(anchor, insert + anchor))
PY
}

patch_gcc_darwin_pch_alignment() {
  local src="$1"
  local host_darwin="${src}/gcc/repo/gcc/config/host-darwin.c"

  [[ -f "$host_darwin" ]] || die "missing ${host_darwin}"
  python3 - "$host_darwin" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "static char pch_address_space[1024*1024*1024] __attribute__((aligned (4096)));"
new = "static char pch_address_space[1024*1024*1024] __attribute__((aligned (16384)));"
if old in text:
    path.write_text(text.replace(old, new))
elif new not in text:
    raise SystemExit("Darwin PCH alignment declaration not found")
PY
}

patch_gcc_makefile() {
  local src="$1"
  local makefile="${src}/gcc-build/Makefile"

  [[ -f "$makefile" ]] || die "missing ${makefile}"
  python3 - "$makefile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
for index, line in enumerate(lines):
    if "--prefix=$(PREFIX)" in line:
        indent = line.split("--", 1)[0]
        if "--disable-nls" not in "".join(lines[index + 1:index + 6]):
            lines.insert(index + 1, f"{indent}--disable-nls \\\n")
            path.write_text("".join(lines))
        break
PY
}

patch_native_makefile() {
  local src="$1"
  local makefile="${src}/native-build/makefile"

  [[ -f "$makefile" ]] || die "missing ${makefile}"
  python3 - "$makefile" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '\twget "$(SDK_URL)" -O downloads/SDK_$(SDK_VERSION).lha'
new = '\t@test -f downloads/SDK_$(SDK_VERSION).lha || wget "$(SDK_URL)" -O downloads/SDK_$(SDK_VERSION).lha'
if old in text and new not in text:
    path.write_text(text.replace(old, new))
PY
}

stage_sdk_archive() {
  local src="$1"
  local staged="${src}/native-build/downloads/SDK_${SDK_VERSION}.lha"

  if [[ -z "$SDK_ARCHIVE" ]]; then
    return
  fi

  [[ -f "$SDK_ARCHIVE" ]] || die "SDK archive not found: ${SDK_ARCHIVE}"
  log "Staging SDK archive ${SDK_ARCHIVE}"
  mkdir -p "$(dirname "$staged")"
  cp "$SDK_ARCHIVE" "$staged"
}

build_cross() {
  local src="$1"
  local args=(
    gcc-cross
    "CROSS_PREFIX=${PREFIX}"
    "SDK_VERSION=${SDK_VERSION}"
    "HOST_GCC=${HOST_CC}"
    "HOST_GXX=${HOST_CXX}"
    "SHELL=${MAKE_SHELL}"
  )

  if [[ -n "$SDK_URL" ]]; then
    args+=("SDK_URL=${SDK_URL}")
  fi

  log "Building ADTools ppc-amigaos-gcc"
  "$MAKE_BIN" -C "${src}/native-build" -j "$JOBS" "${args[@]}"
}

verify_prefix() {
  local prefix="$1"
  local gcc="${prefix}/bin/ppc-amigaos-gcc"

  log "Verifying ${prefix}"
  [[ -x "$gcc" ]] || die "missing compiler: ${gcc}"
  "$gcc" --version | head -n 1
}

main() {
  parse_args "$@"

  [[ "$(uname -s)" == "Darwin" ]] || die "build_mac.sh is intended for macOS"
  if [[ "$WORKDIR" != /* ]]; then
    WORKDIR="${SCRIPT_DIR}/${WORKDIR}"
  fi

  detect_jobs
  log "Using ${JOBS} parallel jobs"
  ensure_brew
  configure_macos_tools
  install_host_shims
  ensure_python_env
  ensure_lha
  ensure_prefix_writable "$PREFIX"

  local src="${WORKDIR}/adtools"
  prepare_source "$src"
  build_cross "$src"
  verify_prefix "$PREFIX"
  log "Done"
}

main "$@"
