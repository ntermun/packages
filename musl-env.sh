#!/usr/bin/env bash
# musl-env.sh - shared environment for the aarch64-linux-musl cross build.
#
# Source this file, do not execute it:
#   . repo/musl-env.sh
#
# The toolchain is the prebuilt musl.cc cross compiler:
#   https://musl.cc/aarch64-linux-musl-cross.tgz
# unpack it into $HOME (giving $HOME/aarch64-linux-musl-cross) or point
# MUSL_CROSS at the unpacked directory.
#
# Everything is linked statically because the device has no musl loader and
# no glibc: the only libc available to packages is the one baked into each
# binary.

: "${MUSL_CROSS:=${HOME}/aarch64-linux-musl-cross}"
: "${NTERMINAL_ARCH:=aarch64}"
: "${NTERMINAL_TARGET:=${NTERMINAL_ARCH}-linux-musl}"

if [[ ! -x $MUSL_CROSS/bin/$NTERMINAL_TARGET-gcc ]]; then
	printf 'musl-env.sh: cannot find %s/bin/%s-gcc\n' "$MUSL_CROSS" "$NTERMINAL_TARGET" >&2
	printf 'Download and unpack the toolchain:\n' >&2
	printf '  curl -fL -o /tmp/aarch64-linux-musl-cross.tgz https://musl.cc/aarch64-linux-musl-cross.tgz\n' >&2
	printf '  tar -xzf /tmp/aarch64-linux-musl-cross.tgz -C "$HOME"\n' >&2
	return 1 2>/dev/null || exit 1
fi

export MUSL_CROSS
export CHOST=$NTERMINAL_TARGET
export CBUILD=${CBUILD:-$(uname -m)-pc-linux-gnu}
export CC=$CHOST-gcc
export CXX=$CHOST-g++
export CPP="$CC -E"
export AR=$CHOST-ar
export AS=$CHOST-as
export LD=$CHOST-ld
export NM=$CHOST-nm
export RANLIB=$CHOST-ranlib
export STRIP=$CHOST-strip
export OBJDUMP=$CHOST-objdump
export READELF=$CHOST-readelf

export JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
# Static everywhere.  -fno-pie/-no-pie keeps ancient configure tests happy and
# avoids "read-only segment has dynamic relocations" from hand-written
# Makefiles (bzip2) that ignore CFLAGS defaults.
export CFLAGS=${CFLAGS:--O2 -pipe -fno-pie}
export CXXFLAGS=${CXXFLAGS:--O2 -pipe -fno-pie}
export LDFLAGS=${LDFLAGS:--static -no-pie}
export MAKEINFO=${MAKEINFO:-true}

export PATH=$MUSL_CROSS/bin:$PATH
export PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}
