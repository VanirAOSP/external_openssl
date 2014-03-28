#!/bin/bash
#
# Copyright (C) 2009 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# This script imports new versions of OpenSSL (http://openssl.org/source) into the
# Android source tree.  To run, (1) fetch the appropriate tarball from the OpenSSL repository,
# (2) check the gpg/pgp signature, and then (3) run:
#   ./import_openssl.sh import openssl-*.tar.gz
#
# IMPORTANT: See README.android for additional details.

# turn on exit on error as well as a warning when it happens
set -e
trap  "echo WARNING: Exiting on non-zero subprocess exit code" ERR;

# Make sure we're in the right directory.
cd $(dirname $0)

# Ensure consistent sorting order / tool output.
export LANG=C
export LC_ALL=C
PERL_EXE="perl -C0"

function die() {
  declare -r message=$1

  echo $message
  exit 1
}

function usage() {
  declare -r message=$1

  if [ ! "$message" = "" ]; then
    echo $message
  fi
  echo "Usage:"
  echo "  ./import_openssl.sh import </path/to/openssl-*.tar.gz>"
  echo "  ./import_openssl.sh regenerate <patch/*.patch>"
  echo "  ./import_openssl.sh generate <patch/*.patch> </path/to/openssl-*.tar.gz>"
  exit 1
}

function main() {
  if [ ! -d patches ]; then
    die "OpenSSL patch directory patches/ not found"
  fi

  if [ ! -f openssl.version ]; then
    die "openssl.version not found"
  fi

  source ./openssl.version
  if [ "$OPENSSL_VERSION" == "" ]; then
    die "Invalid openssl.version; see README.android for more information"
  fi

  OPENSSL_DIR=openssl-$OPENSSL_VERSION
  OPENSSL_DIR_ORIG=$OPENSSL_DIR.orig

  if [ ! -f openssl.config ]; then
    die "openssl.config not found"
  fi

  source ./openssl.config
  if [ "$CONFIGURE_ARGS" == "" -o "$UNNEEDED_SOURCES" == "" -o "$NEEDED_SOURCES" == "" ]; then
    die "Invalid openssl.config; see README.android for more information"
  fi

  declare -r command=$1
  shift || usage "No command specified. Try import, regenerate, or generate."
  if [ "$command" = "import" ]; then
    declare -r tar=$1
    shift || usage "No tar file specified."
    import $tar
  elif [ "$command" = "regenerate" ]; then
    declare -r patch=$1
    shift || usage "No patch file specified."
    [ -d $OPENSSL_DIR ] || usage "$OPENSSL_DIR not found, did you mean to use generate?"
    [ -d $OPENSSL_DIR_ORIG ] || usage "$OPENSSL_DIR_ORIG not found, did you mean to use generate?"
    regenerate $patch
  elif [ "$command" = "generate" ]; then
    declare -r patch=$1
    shift || usage "No patch file specified."
    declare -r tar=$1
    shift || usage "No tar file specified."
    generate $patch $tar
  else
    usage "Unknown command specified $command. Try import, regenerate, or generate."
  fi
}

# Compute the name of an assembly source file generated by one of the
# gen_asm_xxxx() functions below. The logic is the following:
# - if "$2" is not empty, output it directly
# - otherwise, change the file extension of $1 from .pl to .S and output
#   it.
# Usage: default_asm_file "$1" "$2"
#     or default_asm_file "$@"
#
# $1: generator path (perl script)
# $2: optional output file name.
function default_asm_file () {
  if [ "$2" ]; then
    echo "$2"
  else
    echo "${1%%.pl}.S"
  fi
}

# Generate an ARM assembly file.
# $1: generator (perl script)
# $2: [optional] output file name
function gen_asm_arm () {
  local OUT
  OUT=$(default_asm_file "$@")
  $PERL_EXE "$1" > "$OUT"
}

function gen_asm_mips () {
  local OUT
  OUT=$(default_asm_file "$@")
  # The perl scripts expect to run the target compiler as $CC to determine
  # the endianess of the target. Setting CC to true is a hack that forces the scripts
  # to generate little endian output
  CC=true $PERL_EXE "$1" o32 > "$OUT"
}

function gen_asm_x86 () {
  local OUT
  OUT=$(default_asm_file "$@")
  $PERL_EXE "$1" elf -fPIC > "$OUT"
}

function gen_asm_x86_64 () {
  local OUT
  OUT=$(default_asm_file "$@")
  $PERL_EXE "$1" elf "$OUT" > "$OUT"
}


# Filter all items in a list that match a given pattern.
# $1: space-separated list
# $2: egrep pattern.
# Out: items in $1 that match $2
function filter_by_egrep() {
  declare -r pattern=$1
  shift
  echo "$@" | tr ' ' '\n' | grep -e "$pattern" | tr '\n' ' '
}

# Sort and remove duplicates in a space-separated list
# $1: space-separated list
# Out: new space-separated list
function uniq_sort () {
  echo "$@" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

function print_autogenerated_header() {
  echo "# Auto-generated - DO NOT EDIT!"
  echo "# To regenerate, edit openssl.config, then run:"
  echo "#     ./import_openssl.sh import /path/to/openssl-$OPENSSL_VERSION.tar.gz"
  echo "#"
}

# Run Configure and generate headers
# $1: 32 for 32-bit arch, 64 for 64-bit arch
# $2: 1 if building for static version
# Out: returns the cflags and depflags in variable $flags
function generate_build_config_headers() {
  chmod +x ./Configure
  local configure_args_bits=CONFIGURE_ARGS_$1
  local configure_args_stat=''
  local outname=$1
  if [ $2 -eq "1" ] ; then
      configure_args_stat=CONFIGURE_ARGS_STATIC
      outname="static-$1"
  fi

  ./Configure $CONFIGURE_ARGS ${!configure_args_bits} ${!configure_args_stat}

  rm -f apps/CA.pl.bak crypto/opensslconf.h.bak
  mv -f crypto/opensslconf.h crypto/opensslconf-$outname.h
  cp -f crypto/opensslconf-$outname.h include/openssl/opensslconf-$outname.h

  local tmpfile=$(mktemp)
  (grep -e -D Makefile | grep -v CONFIGURE_ARGS= | grep -v OPTIONS= | \
      grep -v -e -DOPENSSL_NO_DEPRECATED) > $tmpfile
  declare -r cflags=$(filter_by_egrep "^-D" $(grep -e "^CFLAG=" $tmpfile))
  declare -r depflags=$(filter_by_egrep "^-D" $(grep -e "^DEPFLAG=" $tmpfile))
  rm -f $tmpfile

  flags="$cflags $depflags"
}

# Run Configure and generate makefiles
function generate_build_config_mk() {
  chmod +x ./Configure
  for bits in 32 64 ; do
    # Header flags are output in $flags, first static, then dynamic
    generate_build_config_headers $bits 1
    local flags_static=$flags
    generate_build_config_headers $bits

    echo "Generating build-config-$bits.mk"
    (
      print_autogenerated_header

      echo "openssl_cflags_$bits := \\"
      for flag in $flags ; do echo "  $flag \\" ; done
      echo ""

      echo "openssl_cflags_static_$bits := \\"
      for flag in $flags_static; do echo "  $flag \\" ; done
      echo ""
    ) > ../build-config-$bits.mk
  done
}

# Generate crypto/opensslconf.h file including arch-specific files
function generate_opensslconf_h() {
  echo "Generating opensslconf.h"
  (
  echo "// Auto-generated - DO NOT EDIT!"
  echo "#if defined(__LP64__)"
  echo "#include \"opensslconf-64.h\""
  echo "#else"
  echo "#include \"opensslconf-32.h\""
  echo "#endif"
  ) > crypto/opensslconf.h
  # Generate a compatible version for the static library builds
  echo "Generating opensslconf-static.h"
  (
  echo "// Auto-generated - DO NOT EDIT!"
  echo "#if defined(__LP64__)"
  echo "#include \"opensslconf-static-64.h\""
  echo "#else"
  echo "#include \"opensslconf-static-32.h\""
  echo "#endif"
  ) > crypto/opensslconf-static.h
  # move it to output include files as well
  cp -f crypto/opensslconf-static.h include/openssl/opensslconf-static.h
}

# Return the value of a computed variable name.
# E.g.:
#   FOO=foo
#   BAR=bar
#   echo $(var_value FOO_$BAR)   -> prints the value of ${FOO_bar}
# $1: Variable name
# Out: variable value
var_value() {
  # Note: don't use 'echo' here, because it's sensitive to values
  #       that begin with an underscore (e.g. "-n")
  eval printf \"%s\\n\" \$$1
}

# Same as var_value, but returns sorted output without duplicates.
# $1: Variable name
# Out: variable value (if space-separated list, sorted with no duplicates)
var_sorted_value() {
  uniq_sort $(var_value $1)
}

# Print the definition of a given variable in a GNU Make build file.
# $1: Variable name (e.g. common_src_files)
# $2: prefix for each variable contents
# $3+: Variable value (e.g. list of sources)
print_vardef_with_prefix_in_mk() {
  declare -r varname=$1
  declare -r prefix=$2
  shift
  shift
  if [ -z "$1" ]; then
    echo "$varname :="
  else
    echo "$varname := \\"
    for src; do
      echo "  $prefix$src \\"
    done
  fi
  echo ""
}
# Print the definition of a given variable in a GNU Make build file.
# $1: Variable name (e.g. common_src_files)
# $2+: Variable value (e.g. list of sources)
print_vardef_in_mk() {
  declare -r varname=$1
  shift
  print_vardef_with_prefix_in_mk $varname "" $@
}

# Same as print_vardef_in_mk, but print a CFLAGS definition from
# a list of compiler defines.
# $1: Variable name (e.g. common_cflags)
# $2: List of defines (e.g. OPENSSL_NO_CAMELLIA ...)
print_defines_in_mk() {
  declare -r varname=$1
  shift
  if [ -z "$1" ]; then
    echo "$varname :="
  else
    echo "$varname := \\"
    for def; do
    echo "  -D$def \\"
    done
  fi
  echo ""
}

# Generate a configuration file like Crypto-config.mk
# This uses variable definitions from openssl.config to build a config
# file that can compute the list of target- and host-specific sources /
# compiler flags for a given component.
#
# $1: Target file name.  (e.g. Crypto-config.mk)
# $2: Variable prefix.   (e.g. CRYPTO)
# $3: "host" or "target"
function generate_config_mk() {
  declare -r output="$1"
  declare -r prefix="$2"
  declare -r all_archs="arm arm64 x86 x86_64 mips"

  echo "Generating $(basename $output)"
  (
    print_autogenerated_header
    echo \
"# This script will append to the following variables:
#
#    LOCAL_CFLAGS
#    LOCAL_C_INCLUDES
#    LOCAL_SRC_FILES_\$(TARGET_ARCH)
#    LOCAL_SRC_FILES_\$(TARGET_2ND_ARCH)
#    LOCAL_CFLAGS_\$(TARGET_ARCH)
#    LOCAL_CFLAGS_\$(TARGET_2ND_ARCH)
#    LOCAL_ADDITIONAL_DEPENDENCIES


LOCAL_ADDITIONAL_DEPENDENCIES += \$(LOCAL_PATH)/$(basename $output)
"

    common_defines=$(var_sorted_value OPENSSL_${prefix}_DEFINES)
    print_defines_in_mk common_cflags $common_defines

    common_sources=$(var_sorted_value OPENSSL_${prefix}_SOURCES)
    print_vardef_in_mk common_src_files $common_sources

    common_includes=$(var_sorted_value OPENSSL_${prefix}_INCLUDES)
    print_vardef_with_prefix_in_mk common_c_includes external/openssl/ $common_includes 

    for arch in $all_archs; do
      arch_defines=$(var_sorted_value OPENSSL_${prefix}_DEFINES_${arch})
      print_defines_in_mk ${arch}_cflags $arch_defines

      arch_sources=$(var_sorted_value OPENSSL_${prefix}_SOURCES_${arch})
      print_vardef_in_mk ${arch}_src_files $arch_sources

      arch_exclude_sources=$(var_sorted_value OPENSSL_${prefix}_SOURCES_EXCLUDES_${arch})
      print_vardef_in_mk ${arch}_exclude_files $arch_exclude_sources

    done

    if [ $3 == "target" ]; then
      echo "
LOCAL_CFLAGS += \$(common_cflags)
LOCAL_C_INCLUDES += \$(common_c_includes)"
      for arch in $all_archs; do
        echo "
LOCAL_SRC_FILES_${arch} += \$(filter-out \$(${arch}_exclude_files),\$(common_src_files) \$(${arch}_src_files))
LOCAL_CFLAGS_${arch} += \$(${arch}_cflags)"
      done
    else
      echo "
ifeq (\$(HOST_OS)-\$(HOST_ARCH),linux-x86)
ifneq (\$(BUILD_HOST_64bit),)
host_arch := x86_64
else
host_arch := x86
endif
else
ifeq (\$(HOST_OS)-\$(HOST_ARCH),linux-x86_64)
host_arch := x86_64
else
\$(warning Unknown host architecture \$(HOST_OS)-\$(HOST_ARCH))
host_arch := unknown
endif
endif

LOCAL_CFLAGS     += \$(common_cflags) \$(\$(host_arch)_cflags)
LOCAL_C_INCLUDES += \$(common_c_includes) \$(local_c_includes)
LOCAL_SRC_FILES  += \$(filter-out \$(\$(host_arch)_exclude_files), \$(common_src_files) \$(\$(host_arch)_src_files))"
    fi
  ) > "$output"
}

function import() {
  declare -r OPENSSL_SOURCE=$1

  untar $OPENSSL_SOURCE readonly
  applypatches $OPENSSL_DIR

  cd $OPENSSL_DIR

  generate_build_config_mk
  generate_opensslconf_h

  cp -f LICENSE ../NOTICE
  touch ../MODULE_LICENSE_BSD_LIKE

  # Avoid checking in symlinks
  for i in `find include/openssl -type l`; do
    target=`readlink $i`
    rm -f $i
    if [ -f include/openssl/$target ]; then
      cp include/openssl/$target $i
    fi
  done

  # Generate arm asm
  gen_asm_arm crypto/aes/asm/aes-armv4.pl
  gen_asm_arm crypto/bn/asm/armv4-gf2m.pl
  gen_asm_arm crypto/bn/asm/armv4-mont.pl
  gen_asm_arm crypto/modes/asm/ghash-armv4.pl
  gen_asm_arm crypto/sha/asm/sha1-armv4-large.pl
  gen_asm_arm crypto/sha/asm/sha256-armv4.pl
  gen_asm_arm crypto/sha/asm/sha512-armv4.pl

  # Generate mips asm
  gen_asm_mips crypto/aes/asm/aes-mips.pl
  gen_asm_mips crypto/bn/asm/mips.pl crypto/bn/asm/bn-mips.S
  gen_asm_mips crypto/bn/asm/mips-mont.pl
  gen_asm_mips crypto/sha/asm/sha1-mips.pl
  gen_asm_mips crypto/sha/asm/sha512-mips.pl crypto/sha/asm/sha256-mips.S

  # Generate x86 asm
  gen_asm_x86 crypto/x86cpuid.pl
  gen_asm_x86 crypto/aes/asm/aes-586.pl
  gen_asm_x86 crypto/aes/asm/vpaes-x86.pl
  gen_asm_x86 crypto/aes/asm/aesni-x86.pl
  gen_asm_x86 crypto/bn/asm/bn-586.pl
  gen_asm_x86 crypto/bn/asm/co-586.pl
  gen_asm_x86 crypto/bn/asm/x86-mont.pl
  gen_asm_x86 crypto/bn/asm/x86-gf2m.pl
  gen_asm_x86 crypto/modes/asm/ghash-x86.pl
  gen_asm_x86 crypto/sha/asm/sha1-586.pl
  gen_asm_x86 crypto/sha/asm/sha256-586.pl
  gen_asm_x86 crypto/sha/asm/sha512-586.pl
  gen_asm_x86 crypto/md5/asm/md5-586.pl
  gen_asm_x86 crypto/des/asm/des-586.pl
  gen_asm_x86 crypto/des/asm/crypt586.pl
  gen_asm_x86 crypto/bf/asm/bf-586.pl

  # Generate x86_64 asm
  gen_asm_x86_64 crypto/x86_64cpuid.pl
  gen_asm_x86_64 crypto/sha/asm/sha1-x86_64.pl
  gen_asm_x86_64 crypto/sha/asm/sha512-x86_64.pl crypto/sha/asm/sha256-x86_64.S
  gen_asm_x86_64 crypto/sha/asm/sha512-x86_64.pl
  gen_asm_x86_64 crypto/modes/asm/ghash-x86_64.pl
  gen_asm_x86_64 crypto/aes/asm/aesni-x86_64.pl
  gen_asm_x86_64 crypto/aes/asm/vpaes-x86_64.pl
  gen_asm_x86_64 crypto/aes/asm/bsaes-x86_64.pl
  gen_asm_x86_64 crypto/aes/asm/aes-x86_64.pl
  gen_asm_x86_64 crypto/aes/asm/aesni-sha1-x86_64.pl
  gen_asm_x86_64 crypto/md5/asm/md5-x86_64.pl
  gen_asm_x86_64 crypto/bn/asm/modexp512-x86_64.pl
  gen_asm_x86_64 crypto/bn/asm/x86_64-mont.pl
  gen_asm_x86_64 crypto/bn/asm/x86_64-gf2m.pl
  gen_asm_x86_64 crypto/bn/asm/x86_64-mont5.pl
  gen_asm_x86_64 crypto/rc4/asm/rc4-x86_64.pl
  gen_asm_x86_64 crypto/rc4/asm/rc4-md5-x86_64.pl

  # Setup android.testssl directory
  mkdir android.testssl
  cat test/testssl | \
    sed 's#../util/shlib_wrap.sh ./ssltest#adb shell /system/bin/ssltest#' | \
    sed 's#../util/shlib_wrap.sh ../apps/openssl#adb shell /system/bin/openssl#' | \
    sed 's#adb shell /system/bin/openssl no-dh#[ `adb shell /system/bin/openssl no-dh` = no-dh ]#' | \
    sed 's#adb shell /system/bin/openssl no-rsa#[ `adb shell /system/bin/openssl no-rsa` = no-dh ]#' | \
    sed 's#../apps/server2.pem#/sdcard/android.testssl/server2.pem#' | \
    cat > \
    android.testssl/testssl
  chmod +x android.testssl/testssl
  cat test/Uss.cnf | sed 's#./.rnd#/sdcard/android.testssl/.rnd#' >> android.testssl/Uss.cnf
  cat test/CAss.cnf | sed 's#./.rnd#/sdcard/android.testssl/.rnd#' >> android.testssl/CAss.cnf
  cp apps/server2.pem android.testssl/
  cp ../patches/testssl.sh android.testssl/

  cd ..

  generate_config_mk Crypto-config-target.mk CRYPTO target
  generate_config_mk Crypto-config-host.mk CRYPTO host
  generate_config_mk Ssl-config-target.mk SSL target
  generate_config_mk Ssl-config-host.mk SSL host
  generate_config_mk Apps-config-target.mk APPS target
  generate_config_mk Apps-config-host.mk APPS host

  # Prune unnecessary sources
  prune

  NEEDED_SOURCES="$NEEDED_SOURCES android.testssl"
  for i in $NEEDED_SOURCES; do
    echo "Updating $i"
    rm -r $i
    mv $OPENSSL_DIR/$i .
  done

  cleantar
}

function regenerate() {
  declare -r patch=$1

  generatepatch $patch
}

function generate() {
  declare -r patch=$1
  declare -r OPENSSL_SOURCE=$2

  untar $OPENSSL_SOURCE
  applypatches $OPENSSL_DIR_ORIG $patch
  prune

  for i in $NEEDED_SOURCES; do
    echo "Restoring $i"
    rm -r $OPENSSL_DIR/$i
    cp -rf $i $OPENSSL_DIR/$i
  done

  generatepatch $patch
  cleantar
}

# Find all files in a sub-directory that are encoded in ISO-8859
# $1: Directory.
# Out: list of files in $1 that are encoded as ISO-8859.
function find_iso8859_files() {
  find $1 -type f -print0 | xargs -0 file --mime-encoding | grep -i "iso-8859" | cut -d: -f1
}

# Convert all ISO-8859 files in a given subdirectory to UTF-8
# $1: Directory name
function convert_iso8859_to_utf8() {
  declare -r iso_files=$(find_iso8859_files "$1")
  for iso_file in $iso_files; do
    iconv --from-code iso-8859-1 --to-code utf-8 $iso_file > $iso_file.tmp
    rm -f $iso_file
    mv $iso_file.tmp $iso_file
  done
}

function untar() {
  declare -r OPENSSL_SOURCE=$1
  declare -r readonly=$2

  # Remove old source
  cleantar

  # Process new source
  tar -zxf $OPENSSL_SOURCE
  convert_iso8859_to_utf8 $OPENSSL_DIR
  cp -rfP $OPENSSL_DIR $OPENSSL_DIR_ORIG
  if [ ! -z $readonly ]; then
    find $OPENSSL_DIR_ORIG -type f -print0 | xargs -0 chmod a-w
  fi
}

function prune() {
  echo "Removing $UNNEEDED_SOURCES"
  (cd $OPENSSL_DIR_ORIG && rm -rf $UNNEEDED_SOURCES)
  (cd $OPENSSL_DIR      && rm -r  $UNNEEDED_SOURCES)
}

function cleantar() {
  rm -rf $OPENSSL_DIR_ORIG
  rm -rf $OPENSSL_DIR
}

function applypatches () {
  declare -r dir=$1
  declare -r skip_patch=$2

  cd $dir

  # Apply appropriate patches
  for i in $OPENSSL_PATCHES; do
    if [ ! "$skip_patch" = "patches/$i" ]; then
      echo "Applying patch $i"
      patch -p1 --merge < ../patches/$i || die "Could not apply patches/$i. Fix source and run: $0 regenerate patches/$i"
    else
      echo "Skiping patch $i"
    fi

  done

  # Cleanup patch output
  find . \( -type f -o -type l \) -name "*.orig" -print0 | xargs -0 rm -f

  cd ..
}

function generatepatch() {
  declare -r patch=$1

  # Cleanup stray files before generating patch
  find $OPENSSL_DIR -type f -name "*.orig" -print0 | xargs -0 rm -f
  find $OPENSSL_DIR -type f -name "*~" -print0 | xargs -0 rm -f

  # Find the files the patch touches and only keep those in the output patch
  declare -r sources=`patch -p1 --dry-run -d $OPENSSL_DIR < $patch  | awk '/^patching file / { print $3 }'`

  rm -f $patch
  touch $patch
  for i in $sources; do
    LC_ALL=C TZ=UTC0 diff -aup $OPENSSL_DIR_ORIG/$i $OPENSSL_DIR/$i >> $patch && die "ERROR: No diff for patch $path in file $i"
  done
  echo "Generated patch $patch"
  echo "NOTE To make sure there are not unwanted changes from conflicting patches, be sure to review the generated patch."
}

main $@
