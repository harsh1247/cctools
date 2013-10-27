#!/bin/bash

ndk_version="r9"

binutils_version="2.23"
gcc_version="4.8"
gmp_version="5.0.5"
mpc_version="1.0.1"
mpfr_version="3.1.1"
cloog_version="0.18.0"
isl_version="0.11.1"
ppl_version="1.0"

make_version="3.82"
ncurses_version="5.9"
nano_version="2.2.6"
busybox_version="1.21.1"
emacs_version="24.2"

binutils_avr_version="2.23"
gcc_avr_version="4.8"

TARGET_INST_DIR="/data/data/com.pdaxrom.cctools/root/cctools"
#TARGET_INST_DIR="/data/data/com.pdaxrom.cctools/cache/cctools"

SRC_PREFIX="$1"

TARGET_ARCH="$2"
HOST_ARCH="$2"

WORK_DIR="$3"

SYSROOT="$4"

NDK_DIR="$5"

if [ "x$SRC_PREFIX" = "x" ]; then
    echo "No source dir"
    exit 1
fi

if [ "x$TARGET_ARCH" = "x" ]; then
    echo "No target arch"
    exit 1
fi

if [ "x$WORK_DIR" = "x" ]; then
    work_dir="/tmp/native-ndk-$TARGET_ARCH-$USER"
else
    work_dir="$WORK_DIR"
fi

if [ "x$NDK_DIR" = "x" ]; then
    NDK_DIR=/opt/android-ndk
fi

if [ "x$MAKEARGS" = "x" ]; then
    MAKEARGS=-j9
fi

TOPDIR="$PWD"

build_dir="$work_dir/build"
src_dir="$work_dir/src"
patch_dir="$TOPDIR/patches"

TARGET_DIR="$work_dir/cctools"
TMPINST_DIR="$build_dir/tmpinst"

MAKE=make
INSTALL=install

XBUILD_ARCH=`uname -m`
BUILD_SYSTEM=`uname`

case $BUILD_SYSTEM in
Linux)
    BUILD_ARCH=${XBUILD_ARCH}-unknown-linux
    ;;
Darwin)
    BUILD_ARCH=${XBUILD_ARCH}-unknown-darwin
    ;;
CYGWIN*)
    BUILD_ARCH=${XBUILD_ARCH}-unknown-cygwin
    ;;
*)
    BUILD_ARCH=
    echo "unknown host system!"
    exit 1
    ;;
esac

case $TARGET_ARCH in
arm*)
    TARGET_ARCH_GLIBC=arm-none-linux-gnueabi
    ;;
mips*)
    TARGET_ARCH_GLIBC=mips-linux-gnu
    ;;
i*86*|x86*)
    TARGET_ARCH_GLIBC=i686-pc-linux-gnu
    ;;
*)
    echo "unknown arch $TARGET_ARCH"
    exit 1
    ;;
esac

echo "Target arch: $TARGET_ARCH"
echo "Host   arch: $HOST_ARCH"
echo "Build  arch: $BUILD_ARCH"

banner() {
    echo
    echo "*********************************************************************************"
    echo "$1"
    echo
    if [ "$TERM" = "xterm-color" -o "$TERM" = "xterm" ]; then
	echo -ne "\033]0;${1}\007"
    fi
}

trap "banner ''" 2

error() {
    echo
    echo "*********************************************************************************"
    echo "Error: $@"
    echo
    exit 1
}

makedirs() {
    mkdir -p $src_dir
    mkdir -p $work_dir/tags
    mkdir -p ${TMPINST_DIR}/libso
}

s_tag() {
    touch $work_dir/tags/$1
}

c_tag() {
    test -e $work_dir/tags/$1
}

copysrc() {
    mkdir -p $2
    tar -C "$1" -c . | tar -C $2 -xv || error "copysrc $1 $2"
}

preparesrc() {
    if [ ! -d $2 ]; then
	pushd .
	copysrc $1 $2
	cd $2
	patch -p1 < $patch_dir/`basename $2`.patch
	popd
    fi
}

download() {
    if [ ! -e $2 ]; then
	mkdir -p `dirname $2`
	echo "Downloading..."
	wget $1 -O $2 || error "download $PKG_URL"
    fi
}

unpack() {
    local cmd=

    echo "Unpacking..."

    case $2 in
    *.tar.gz|*.tgz)
	cmd="tar zxf $2 -C $1"
	;;
    *.tar.bz2| *.tbz)
	cmd="tar jxf $2 -C $1"
	;;
    *.tar.xz)
	cmd="tar Jxf $2 -C $1"
	;;
    *)
	error "Unknown archive type."
	;;
    esac

    $cmd || error "Corrupted archive $2."
}

patchsrc() {
    if [ -f $patch_dir/${2}-${3}.patch ]; then
	pushd .
	cd $1
	patch -p1 < $patch_dir/${2}-${3}.patch || error "Correpted patch file."
	popd
    fi
}

#
# find deps
#

get_pkg_libso_list() {
    local f
    find $1 -type f -name "*.so" -o -name "*.so.*" | while read f; do
	if readelf -h $f 2>/dev/null | grep -q "DYN"; then
	    echo -n "`basename ${f}` "
	fi
    done
}

get_pkg_exec_list() {
    local f
    find $1 -type f -executable | while read f; do
	if readelf -h $f 2>/dev/null | grep -q "EXEC"; then
	    echo $f
	fi
    done
}

get_libso_list() {
    strings $1 | grep "^lib.*so*"
}

get_pkg_external_libso() {
    local exes=`get_pkg_exec_list $1`
    ( for f in $exes; do
	get_libso_list $f
    done ) | sort | uniq
}

get_dep_packages() {
    #echo "Package $1"
    local f
    for f in `get_pkg_external_libso $2`; do
	local d
	for d in ${TMPINST_DIR}/libso/*.txt; do
	    if grep -q $f $d; then
		local p=`cat $d | cut -f1 -d:`
		if [ "$p" != "$1" ]; then
		    echo $p
		fi
	    fi
	done
    done
}

get_pkg_deps() {
    local list=`get_pkg_libso_list $2 | sort`
    echo "$1: $list" > ${TMPINST_DIR}/libso/$1.txt
    local pkgs=`get_dep_packages $1 $2 | sort | uniq`
    echo $pkgs
}

#
# build_package_desc <path> <filename> <name> <version> <arch> <description>
#

build_package_desc() {
    local filename=$2
    local name=$3
    local vers=$4
    local arch=$5
    local desc=$6

    local unpacked_size=`du -sb ${1}/cctools | cut -f1`

    local deps="`get_pkg_deps $name $1`"
    if [ "x$7" != "x" ]; then
	deps="$deps $7"
    fi

cat >$1/pkgdesc << EOF
    <package>
	<name>$name</name>
	<version>$vers</version>
	<arch>$arch</arch>
	<description>$desc</description>
	<depends>$deps</depends>
	<size>$unpacked_size</size>
	<file>$filename</file>
	<filesize>@SIZE@</filesize>
    </package>
EOF

}

case $TARGET_ARCH in
arm*)
    PKG_ARCH="armel"
    ;;
mips*)
    PKG_ARCH="mipsel"
    ;;
i*86*)
    PKG_ARCH="i686"
    ;;
*)
    error "Can't set PKG_ARCH from $TARGET_ARCH"
    ;;
esac

for f in rules/*.sh; do
    echo "Include $f"
    . $f
done

makedirs

# Toolchain support libs
build_gmp_host
build_gmp
build_mpfr_host
build_mpfr
build_mpc_host
build_mpc
build_isl_host
build_isl
build_ppl_host
build_ppl
build_cloog_host
build_cloog

# CCTools native tools moved from bundle
build_binutils
build_gcc
build_cxxstl
build_make
build_ndk_misc
build_ndk_sysroot

# Clang
build_llvm

# Addons
build_ncurses
build_libiconv
#build_libffi
#build_gettext
build_glib_host
build_glib
#build_slang
build_mc
build_busybox
build_htop
build_luajit
build_openssl
build_expat
build_sqlite
build_apr
build_aprutil
build_neon
build_subversion
build_curl
build_wget
build_git
build_dropbear
#build_fpc
#build_nano
#build_emacs
build_binutils_avr_host
build_binutils_avr
build_gcc_avr_host
build_gcc_avr
build_avr_libc
build_fortran_host
build_fortran
build_fortran_examples
build_netcat
