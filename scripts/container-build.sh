#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Safety settings (see https://gist.github.com/ilg-ul/383869cbb01f61a51c4d).

if [[ ! -z ${DEBUG} ]]
then
  set ${DEBUG} # Activate the expand mode if DEBUG is anything but empty.
else
  DEBUG=""
fi

set -o errexit # Exit if command failed.
set -o pipefail # Exit if pipe failed.
set -o nounset # Exit if variable not set.

# Remove the initial space and instead use '\n'.
IFS=$'\n\t'

# -----------------------------------------------------------------------------

# Inner script to run inside Docker containers to build the 
# GNU MCU Eclipse RISC-V Embedded GCC distribution packages.

# For native builds, it runs on the host (macOS build cases,
# and development builds for GNU/Linux).

# -----------------------------------------------------------------------------

# ----- Identify helper scripts. -----

build_script_path=$0
if [[ "${build_script_path}" != /* ]]
then
  # Make relative path absolute.
  build_script_path=$(pwd)/$0
fi

script_folder_path="$(dirname ${build_script_path})"
script_folder_name="$(basename ${script_folder_path})"

defines_script_path="${script_folder_path}/defs-source.sh"
echo "Definitions source script: \"${defines_script_path}\"."
source "${defines_script_path}"

TARGET_OS=""
TARGET_BITS=""
HOST_UNAME=""

# This file is generated by the host build script.
host_defines_script_path="${script_folder_path}/host-defs-source.sh"
echo "Host definitions source script: \"${host_defines_script_path}\"."
source "${host_defines_script_path}"

container_lib_functions_script_path="${script_folder_path}/${CONTAINER_LIB_FUNCTIONS_SCRIPT_NAME}"
echo "Container lib functions source script: \"${container_lib_functions_script_path}\"."
source "${container_lib_functions_script_path}"

container_app_functions_script_path="${script_folder_path}/${CONTAINER_APP_FUNCTIONS_SCRIPT_NAME}"
echo "Container app functions source script: \"${container_app_functions_script_path}\"."
source "${container_app_functions_script_path}"

container_functions_script_path="${script_folder_path}/helper/container-functions-source.sh"
echo "Container helper functions source script: \"${container_functions_script_path}\"."
source "${container_functions_script_path}"

# -----------------------------------------------------------------------------

WITH_STRIP="y"
WITHOUT_MULTILIB=""
WITH_PDF="y"
WITH_HTML="n"
IS_DEVELOP=""
IS_DEBUG=""
LINUX_INSTALL_PATH=""
USE_GITS=""

# Attempts to use 8 occasionally failed, reduce if necessary.
if [ "$(uname)" == "Darwin" ]
then
  JOBS="--jobs=$(sysctl -n hw.ncpu)"
else
  JOBS="--jobs=$(grep ^processor /proc/cpuinfo|wc -l)"
fi

while [ $# -gt 0 ]
do

  case "$1" in

    --disable-strip)
      WITH_STRIP="n"
      shift
      ;;

    --without-pdf)
      WITH_PDF="n"
      shift
      ;;

    --with-pdf)
      WITH_PDF="y"
      shift
      ;;

    --without-html)
      WITH_HTML="n"
      shift
      ;;

    --with-html)
      WITH_HTML="y"
      shift
      ;;

    --disable-multilib)
      WITHOUT_MULTILIB="y"
      shift
      ;;

    --jobs)
      JOBS="--jobs=$2"
      shift 2
      ;;

    --develop)
      IS_DEVELOP="y"
      shift
      ;;

    --debug)
      IS_DEBUG="y"
      WITH_STRIP="n"
      shift
      ;;

    --use-gits)
      USE_GITS="y"
      shift
      ;;

    --linux-install-path)
      LINUX_INSTALL_PATH="$2"
      shift 2
      ;;

    *)
      echo "Unknown action/option $1"
      exit 1
      ;;

  esac

done

# -----------------------------------------------------------------------------

start_timer

detect_container

# Fix the texinfo path in XBB v1.
if [ -f "/.dockerenv" -a -f "/opt/xbb/xbb.sh" ]
then
  if [ "${TARGET_BITS}" == "64" ]
  then
    sed -e "s|texlive/bin/\$\(uname -p\)-linux|texlive/bin/x86_64-linux|" /opt/xbb/xbb.sh > /opt/xbb/xbb-source.sh
  elif [ "${TARGET_BITS}" == "32" ]
  then
    sed -e "s|texlive/bin/[$][(]uname -p[)]-linux|texlive/bin/i386-linux|" /opt/xbb/xbb.sh > /opt/xbb/xbb-source.sh
  fi

  echo /opt/xbb/xbb-source.sh
  cat /opt/xbb/xbb-source.sh
fi

prepare_prerequisites

if [ -f "/.dockerenv" ]
then
  ( 
    xbb_activate

    # Remove references to libfl.so, to force a static link and
    # avoid references to unwanted shared libraries in binutils.
    sed -i -e "s/dlname=.*/dlname=''/" -e "s/library_names=.*/library_names=''/" "${XBB_FOLDER}"/lib/libfl.la

    echo "${XBB_FOLDER}"/lib/libfl.la
    cat "${XBB_FOLDER}"/lib/libfl.la
  )
fi

if [ -x "${WORK_FOLDER_PATH}/${LINUX_INSTALL_PATH}/bin/${GCC_TARGET}-gcc" ]
then
  PATH="${WORK_FOLDER_PATH}/${LINUX_INSTALL_PATH}/bin":${PATH}
  echo ${PATH}
fi

# -----------------------------------------------------------------------------

UNAME="$(uname)"

# Make all tools choose gcc, not the old cc.
if [ "${UNAME}" == "Darwin" ]
then
  # For consistency, even on macOS, prefer GCC 7 over clang.
  # (Also because all GCC pre 7 versions fail with 'bracket nesting level 
  # exceeded' with clang; not to mention the too many warnings.)
  # However the oof-the-shelf GCC 7 has a problem, and requires patching,
  # otherwise the generated GDB fails with SIGABRT; to test use 'set 
  # language auto').
  export CC=gcc-7.2.0-patched
  export CXX=g++-7.2.0-patched
elif [ "${TARGET_OS}" == "linux" ]
then
  export CC=gcc
  export CXX=g++
fi

EXTRA_CFLAGS="-ffunction-sections -fdata-sections -m${TARGET_BITS} -pipe"
EXTRA_CXXFLAGS="-ffunction-sections -fdata-sections -m${TARGET_BITS} -pipe"

if [ "${IS_DEBUG}" == "y" ]
then
  EXTRA_CFLAGS+=" -g -O0"
  EXTRA_CXXFLAGS+=" -g -O0"
else
  EXTRA_CFLAGS+=" -O2"
  EXTRA_CXXFLAGS+=" -O2"
fi

EXTRA_CPPFLAGS="-I${INSTALL_FOLDER_PATH}"/include
EXTRA_LDFLAGS_LIB="-L${INSTALL_FOLDER_PATH}"/lib
EXTRA_LDFLAGS="${EXTRA_LDFLAGS_LIB}"
if [ "${IS_DEBUG}" == "y" ]
then
  EXTRA_LDFLAGS+=" -g"
fi

if [ "${TARGET_OS}" == "macos" ]
then
  # Note: macOS linker ignores -static-libstdc++, so 
  # libstdc++.6.dylib should be handled.
  EXTRA_LDFLAGS_APP="${EXTRA_LDFLAGS} -Wl,-dead_strip"
elif [ "${TARGET_OS}" == "linux" ]
then
  # Do not add -static here, it fails.
  # Do not try to link pthread statically, it must match the system glibc.
  EXTRA_LDFLAGS_APP+="${EXTRA_LDFLAGS} -static-libstdc++ -Wl,--gc-sections"
elif [ "${TARGET_OS}" == "win" ]
then
  # CRT_glob is from ARM script
  # -static avoids libwinpthread-1.dll 
  # -static-libgcc avoids libgcc_s_sjlj-1.dll 
  EXTRA_LDFLAGS_APP+="${EXTRA_LDFLAGS} -static -static-libgcc -static-libstdc++ -Wl,--gc-sections"
fi

export PKG_CONFIG=pkg-config-verbose
export PKG_CONFIG_LIBDIR="${INSTALL_FOLDER_PATH}"/lib/pkgconfig

APP_PREFIX="${INSTALL_FOLDER_PATH}/${APP_LC_NAME}"
APP_PREFIX_DOC="${APP_PREFIX}"/share/doc

APP_PREFIX_NANO="${INSTALL_FOLDER_PATH}/${APP_LC_NAME}"-nano

# The \x2C is a comma in hex; without this trick the regular expression
# that processes this string in the Makefile, silently fails and the 
# bfdver.h file remains empty.
BRANDING="${BRANDING}\x2C ${TARGET_BITS}-bits"
CFLAGS_OPTIMIZATIONS_FOR_TARGET="-ffunction-sections -fdata-sections -O2"
# Cannot use medlow with 64 bits, so all must be medany.
CFLAGS_OPTIMIZATIONS_FOR_TARGET+=" -mcmodel=medany"

BINUTILS_PROJECT_NAME="riscv-binutils-gdb"
GCC_PROJECT_NAME="riscv-none-gcc"
NEWLIB_PROJECT_NAME="riscv-newlib"

MULTILIB_FLAGS=""

# Keep them in sync with combo archive content.
if [[ "${RELEASE_VERSION}" =~ 7\.2\.0-3-* ]]
then

  # ---------------------------------------------------------------------------

  # The default is:
  # rv32i-ilp32--c rv32im-ilp32--c rv32iac-ilp32-- rv32imac-ilp32-- rv32imafc-ilp32f-rv32imafdc- rv64imac-lp64-- rv64imafdc-lp64d--
  # Add 'rv32imaf-ilp32f--'. 
  GCC_MULTILIB=(rv32i-ilp32--c rv32im-ilp32--c rv32iac-ilp32-- rv32imac-ilp32-- rv32imaf-ilp32f-- rv32imafc-ilp32f-rv32imafdc- rv64imac-lp64-- rv64imafdc-lp64d--)

  GCC_MULTILIB_FILE=${GCC_MULTILIB_FILE:-"t-elf-multilib"}

  # ---------------------------------------------------------------------------

  BINUTILS_VERSION="2.29"
  # From gcc/BASE_VER
  GCC_VERSION="7.2.0"
  # From newlib/configure, VERSION=
  NEWLIB_VERSION="2.5.0"
  # From gdb/VERSION.in
  GDB_VERSION="8.0"

  # ---------------------------------------------------------------------------

  if [ "${USE_GITS}" != "y" ]
  then

    GH_RELEASE="7.2.0-3-20180506"
    BINUTILS_GH_RELEASE=${BINUTILS_GH_RELEASE:-"${GH_RELEASE}"}
    GCC_GH_RELEASE=${GCC_GH_RELEASE:-"${GH_RELEASE}"}
    NEWLIB_GH_RELEASE=${NEWLIB_GH_RELEASE:-"${GH_RELEASE}"}

  else

    BINUTILS_GIT_BRANCH=${BINUTILS_GIT_BRANCH:-"riscv-binutils-2.29-gme"}
    # June 17, 2017
    BINUTILS_GIT_COMMIT=${BINUTILS_GIT_COMMIT:-"a8d8cd7ff85a945b30ddd484a4d7592af3ed8fbb"}

    GCC_GIT_BRANCH=${GCC_GIT_BRANCH:-"riscv-gcc-7.2.0-gme"}
    GCC_GIT_COMMIT=${GCC_GIT_COMMIT:-"ea82ccadd6c4906985249c52009deddc6b623b16"}

    NEWLIB_GIT_BRANCH=${NEWLIB_GIT_BRANCH:-"riscv-newlib-2.5.0-gme"}
    NEWLIB_GIT_COMMIT=${NEWLIB_GIT_COMMIT:-"325bec1e33fb0a1c30ce5a9aeeadd623f559ef1a"}

  fi
  
  # ---------------------------------------------------------------------------

  ZLIB_VERSION="1.2.8"
  GMP_VERSION="6.1.2"
  MPFR_VERSION="3.1.6"
  MPC_VERSION="1.0.3"
  ISL_VERSION="0.18"
  LIBELF_VERSION="0.8.13"
  EXPAT_VERSION="2.2.5"
  LIBICONV_VERSION="1.15"
  XZ_VERSION="5.2.3"

  PYTHON_WIN_VERSION="2.7.13"

  # ---------------------------------------------------------------------------
elif [[ "${RELEASE_VERSION}" =~ 7\.2\.0-4-* ]]
then

  # ---------------------------------------------------------------------------

  # The default is:
  # rv32i-ilp32--c rv32im-ilp32--c rv32iac-ilp32-- rv32imac-ilp32-- rv32imafc-ilp32f-rv32imafdc- rv64imac-lp64-- rv64imafdc-lp64d--
  # Add 'rv32imaf-ilp32f--'. 
  GCC_MULTILIB=(rv32i-ilp32--c rv32im-ilp32--c rv32iac-ilp32-- rv32imac-ilp32-- rv32imaf-ilp32f-- rv32imafc-ilp32f-rv32imafdc- rv64imac-lp64-- rv64imafdc-lp64d--)

  GCC_MULTILIB_FILE=${GCC_MULTILIB_FILE:-"t-elf-multilib"}

  # ---------------------------------------------------------------------------

  BINUTILS_VERSION="2.29"
  # From gcc/BASE_VER
  GCC_VERSION="7.2.0"
  # From newlib/configure, VERSION=
  NEWLIB_VERSION="2.5.0"
  # From gdb/VERSION.in
  GDB_VERSION="8.0"

  # ---------------------------------------------------------------------------

  if [ "${USE_GITS}" != "y" ]
  then

    GH_RELEASE="7.2.0-4-20180606"
    BINUTILS_GH_RELEASE=${BINUTILS_GH_RELEASE:-"${GH_RELEASE}"}
    GCC_GH_RELEASE=${GCC_GH_RELEASE:-"${GH_RELEASE}"}
    NEWLIB_GH_RELEASE=${NEWLIB_GH_RELEASE:-"${GH_RELEASE}"}

  else

    BINUTILS_GIT_BRANCH=${BINUTILS_GIT_BRANCH:-"riscv-binutils-2.29-gme"}
    # June 17, 2017
    BINUTILS_GIT_COMMIT=${BINUTILS_GIT_COMMIT:-"a8d8cd7ff85a945b30ddd484a4d7592af3ed8fbb"}

    GCC_GIT_BRANCH=${GCC_GIT_BRANCH:-"riscv-gcc-7.2.0-gme"}
    GCC_GIT_COMMIT=${GCC_GIT_COMMIT:-"ea82ccadd6c4906985249c52009deddc6b623b16"}

    NEWLIB_GIT_BRANCH=${NEWLIB_GIT_BRANCH:-"riscv-newlib-2.5.0-gme"}
    NEWLIB_GIT_COMMIT=${NEWLIB_GIT_COMMIT:-"325bec1e33fb0a1c30ce5a9aeeadd623f559ef1a"}

  fi
  
  # ---------------------------------------------------------------------------

  ZLIB_VERSION="1.2.8"
  GMP_VERSION="6.1.2"
  MPFR_VERSION="3.1.6"
  MPC_VERSION="1.0.3"
  ISL_VERSION="0.18"
  LIBELF_VERSION="0.8.13"
  EXPAT_VERSION="2.2.5"
  LIBICONV_VERSION="1.15"
  XZ_VERSION="5.2.3"

  PYTHON_WIN_VERSION="2.7.13"

  # ---------------------------------------------------------------------------
elif [[ "${RELEASE_VERSION}" =~ 7\.3\.0-* ]]
then

  # WARNING: Experimental, do not use for releases!

  # ---------------------------------------------------------------------------

  # The default is:
  # rv32i-ilp32--c rv32im-ilp32--c rv32iac-ilp32-- rv32imac-ilp32-- rv32imafc-ilp32f-rv32imafdc- rv64imac-lp64-- rv64imafdc-lp64d--
  # Add 'rv32imaf-ilp32f--'. 
  GCC_MULTILIB=(rv32i-ilp32--c rv32im-ilp32--c rv32iac-ilp32-- rv32imac-ilp32-- rv32imaf-ilp32f-- rv32imafc-ilp32f-rv32imafdc- rv64imac-lp64-- rv64imafdc-lp64d--)

  GCC_MULTILIB_FILE=${GCC_MULTILIB_FILE:-"t-elf-multilib"}

  # ---------------------------------------------------------------------------

  BINUTILS_VERSION="2.29"
  # From gcc/BASE_VER
  GCC_VERSION="7.3.0"
  # From newlib/configure, VERSION=
  NEWLIB_VERSION="2.5.0"
  # From gdb/VERSION.in
  GDB_VERSION="8.0"

  # ---------------------------------------------------------------------------

  if [ "${USE_GITS}" != "y" ]
  then

    GH_RELEASE="7.3.0-1-20180506"
    BINUTILS_GH_RELEASE=${BINUTILS_GH_RELEASE:-"${GH_RELEASE}"}
    GCC_GH_RELEASE=${GCC_GH_RELEASE:-"${GH_RELEASE}"}
    NEWLIB_GH_RELEASE=${NEWLIB_GH_RELEASE:-"${GH_RELEASE}"}

  else

    BINUTILS_GIT_BRANCH=${BINUTILS_GIT_BRANCH:-"riscv-binutils-2.29-gme"}
    # June 17, 2017
    BINUTILS_GIT_COMMIT=${BINUTILS_GIT_COMMIT:-"a8d8cd7ff85a945b30ddd484a4d7592af3ed8fbb"}

    GCC_GIT_BRANCH=${GCC_GIT_BRANCH:-"riscv-gcc-7.3.0-gme"}
    GCC_GIT_COMMIT=${GCC_GIT_COMMIT:-"6d6363ebaf0190dc5af3ff09bc5416d4228fdfa2"}

    NEWLIB_GIT_BRANCH=${NEWLIB_GIT_BRANCH:-"riscv-newlib-2.5.0-gme"}
    NEWLIB_GIT_COMMIT=${NEWLIB_GIT_COMMIT:-"325bec1e33fb0a1c30ce5a9aeeadd623f559ef1a"}

  fi
  
  # ---------------------------------------------------------------------------

  ZLIB_VERSION="1.2.8"
  GMP_VERSION="6.1.2"
  MPFR_VERSION="3.1.6"
  MPC_VERSION="1.0.3"
  ISL_VERSION="0.18"
  LIBELF_VERSION="0.8.13"
  EXPAT_VERSION="2.2.5"
  LIBICONV_VERSION="1.15"
  XZ_VERSION="5.2.3"

  PYTHON_WIN_VERSION="2.7.13"

  # ---------------------------------------------------------------------------
else
  echo "Unsupported version ${RELEASE_VERSION}."
  exit 1
fi

if [ "${USE_GITS}" != "y" ]
then

  # ---------------------------------------------------------------------------

  BINUTILS_SRC_FOLDER_NAME=${BINUTILS_SRC_FOLDER_NAME:-"${BINUTILS_PROJECT_NAME}-${BINUTILS_GH_RELEASE}"}
  BINUTILS_ARCHIVE_NAME=${BINUTILS_ARCHIVE_NAME:-"${BINUTILS_SRC_FOLDER_NAME}.tar.gz"}

  BINUTILS_ARCHIVE_URL=${BINUTILS_ARCHIVE_URL:-"https://github.com/gnu-mcu-eclipse/${BINUTILS_PROJECT_NAME}/archive/v${BINUTILS_GH_RELEASE}.tar.gz"}

  BINUTILS_GIT_URL=""

  # ---------------------------------------------------------------------------

  GCC_SRC_FOLDER_NAME=${GCC_SRC_FOLDER_NAME:-"${GCC_PROJECT_NAME}-${GCC_GH_RELEASE}"}
  GCC_ARCHIVE_NAME=${GCC_ARCHIVE_NAME:-"${GCC_SRC_FOLDER_NAME}.tar.gz"}

  GCC_ARCHIVE_URL=${GCC_ARCHIVE_URL:-"https://github.com/gnu-mcu-eclipse/${GCC_PROJECT_NAME}/archive/v${GCC_GH_RELEASE}.tar.gz"}

  GCC_GIT_URL=""

  # ---------------------------------------------------------------------------

  NEWLIB_SRC_FOLDER_NAME=${NEWLIB_SRC_FOLDER_NAME:-"${NEWLIB_PROJECT_NAME}-${NEWLIB_GH_RELEASE}"}
  NEWLIB_ARCHIVE_NAME=${NEWLIB_ARCHIVE_NAME:-"${NEWLIB_SRC_FOLDER_NAME}.tar.gz"}

  NEWLIB_ARCHIVE_URL=${NEWLIB_ARCHIVE_URL:-"https://github.com/gnu-mcu-eclipse/${NEWLIB_PROJECT_NAME}/archive/v${NEWLIB_GH_RELEASE}.tar.gz"}

  NEWLIB_GIT_URL=""

  # ---------------------------------------------------------------------------
else
  # ---------------------------------------------------------------------------

  BINUTILS_SRC_FOLDER_NAME=${BINUTILS_SRC_FOLDER_NAME:-"${BINUTILS_PROJECT_NAME}.git"}

  BINUTILS_GIT_URL=${BINUTILS_GIT_URL:-"https://github.com/gnu-mcu-eclipse/riscv-binutils-gdb.git"}

  BINUTILS_ARCHIVE_URL=""

  # ---------------------------------------------------------------------------

  GCC_SRC_FOLDER_NAME=${GCC_SRC_FOLDER_NAME:-"${GCC_PROJECT_NAME}.git"}

  GCC_GIT_URL=${GCC_GIT_URL:-"https://github.com/gnu-mcu-eclipse/riscv-none-gcc.git"}

  GCC_ARCHIVE_URL=""

  # ---------------------------------------------------------------------------

  NEWLIB_SRC_FOLDER_NAME=${NEWLIB_SRC_FOLDER_NAME:-"${NEWLIB_PROJECT_NAME}.git"}
    
  NEWLIB_GIT_URL=${NEWLIB_GIT_URL:-"https://github.com/gnu-mcu-eclipse/riscv-newlib.git"}

  NEWLIB_ARCHIVE_URL=""

  # ---------------------------------------------------------------------------
fi

BINUTILS_FOLDER_NAME="binutils-${BINUTILS_VERSION}-gdb-${GDB_VERSION}"
GCC_FOLDER_NAME="gcc-${GCC_VERSION}"
NEWLIB_FOLDER_NAME="newlib-${NEWLIB_VERSION}"

GDB_FOLDER_NAME="${BINUTILS_FOLDER_NAME}"/gdb
GDB_SRC_FOLDER_NAME="${BINUTILS_SRC_FOLDER_NAME}"/gdb

# Note: The 5.x build failed with various messages.

if [ "${WITHOUT_MULTILIB}" == "y" ]
then
  MULTILIB_FLAGS="--disable-multilib"
fi

if [ "${TARGET_BITS}" == "32" ]
then
  PYTHON_WIN=python-"${PYTHON_WIN_VERSION}"
else
  PYTHON_WIN=python-"${PYTHON_WIN_VERSION}".amd64
fi

PYTHON_WIN_PACK="${PYTHON_WIN}".msi
PYTHON_WIN_URL="https://www.python.org/ftp/python/${PYTHON_WIN_VERSION}/${PYTHON_WIN_PACK}"

# -----------------------------------------------------------------------------

echo
echo "Here we go..."
echo

if [ "${TARGET_OS}" == "win" ]
then
  # The Windows GDB needs some headers from the Python distribution.
  download_python
fi

# -----------------------------------------------------------------------------
# Build dependent libraries.

# For better control, without it some components pick the lib packed 
# inside the archive.
do_zlib

# The classical GCC libraries.
do_gmp
do_mpfr
do_mpc
do_isl

# More libraries.
do_libelf
do_expat
do_libiconv
do_xz

# -----------------------------------------------------------------------------

# The task descriptions are from the ARM build script.

# Task [III-0] /$HOST_NATIVE/binutils/
# Task [IV-1] /$HOST_MINGW/binutils/
do_binutils
# copy_dir to libs included above

if [ "${TARGET_OS}" != "win" ]
then

  # Task [III-1] /$HOST_NATIVE/gcc-first/
  do_gcc_first

  # Task [III-2] /$HOST_NATIVE/newlib/
  do_newlib ""
  # Task [III-3] /$HOST_NATIVE/newlib-nano/
  do_newlib "-nano"

  # Task [III-4] /$HOST_NATIVE/gcc-final/
  do_gcc_final ""

  # Task [III-5] /$HOST_NATIVE/gcc-size-libstdcxx/
  do_gcc_final "-nano"

else

  # Task [IV-2] /$HOST_MINGW/copy_libs/
  copy_linux_libs

  # Task [IV-3] /$HOST_MINGW/gcc-final/
  do_gcc_final ""

fi

# Task [III-6] /$HOST_NATIVE/gdb/
# Task [IV-4] /$HOST_MINGW/gdb/
do_gdb ""
do_gdb "-py"

# Task [III-7] /$HOST_NATIVE/build-manual
# Nope, the build process is different.

# -----------------------------------------------------------------------------

# Task [III-8] /$HOST_NATIVE/pretidy/
# Task [IV-5] /$HOST_MINGW/pretidy/
tidy_up

# Task [III-9] /$HOST_NATIVE/strip_host_objects/
# Task [IV-6] /$HOST_MINGW/strip_host_objects/
strip_binaries

if [ "${TARGET_OS}" != "win" ]
then
  # Task [III-10] /$HOST_NATIVE/strip_target_objects/
  strip_libs
fi

check_binaries

copy_gme_files

# Task [IV-7] /$HOST_MINGW/installation/
# Nope, no setup.exe.

# Task [III-11] /$HOST_NATIVE/package_tbz2/
# Task [IV-8] /Package toolchain in zip format/
create_archive

# Change ownership to non-root Linux user.
fix_ownership

# -----------------------------------------------------------------------------

echo
echo "Done."

stop_timer

exit 0

# -----------------------------------------------------------------------------
