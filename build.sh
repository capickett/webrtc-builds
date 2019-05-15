#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $DIR/util.sh

usage ()
{
cat << EOF

Usage:
   $0 [OPTIONS]

WebRTC automated build script.

OPTIONS:
   -o OUTDIR      Output directory. Default is 'out'
   -d DEPOT_TOOLS Location where depot_tools are installed.
   -v             Debug mode. Print all executed commands.
   -h             Show this message
EOF
}

while getopts :o:d:xDv OPTION; do
  case $OPTION in
  o) OUTDIR=$OPTARG ;;
  d) DEPOT_TOOLS_DIR=$OPTARG ;;
  v) DEBUG=1 ;;
  ?) usage; exit 1 ;;
  esac
done

OUTDIR=${OUTDIR:-out}
DEBUG=${DEBUG:-0}
CONFIGS=${CONFIGS:-Debug Release}
PACKAGE_FILENAME_PATTERN=${PACKAGE_FILENAME_PATTERN:-"webrtc-%to%-%tc%"}
REPO_URL="https://webrtc.googlesource.com/src"
DEPOT_TOOLS_DIR=${DEPOT_TOOLS_DIR:-depot_tools}
PATH=$DEPOT_TOOLS_DIR:$DEPOT_TOOLS_DIR/python276_bin:$PATH

[ "$DEBUG" = 1 ] && set -x

mkdir -p $OUTDIR
OUTDIR=$(cd $OUTDIR && pwd -P)

detect-platform
TARGET_OS=${TARGET_OS:-$PLATFORM}
TARGET_CPU=${TARGET_CPU:-x64}

echo "Host OS: $PLATFORM"
echo "Target OS: $TARGET_OS"
echo "Target CPU: $TARGET_CPU"

echo Checking build environment dependencies
check::build::env $PLATFORM "$TARGET_CPU"

echo Checking depot-tools
check::depot-tools $DEPOT_TOOLS_DIR

echo "Checking out WebRTC (this will take a while)"
checkout $OUTDIR

echo Checking WebRTC dependencies
check::webrtc::deps $PLATFORM $OUTDIR

echo Compiling WebRTC
compile $PLATFORM $OUTDIR "$TARGET_OS" "$TARGET_CPU" "$CONFIGS"

# Default PACKAGE_FILENAME is <projectname>-<target-os>-<target-cpu>
PACKAGE_FILENAME=$(interpret-pattern "$PACKAGE_FILENAME_PATTERN" "$TARGET_OS" "$TARGET_CPU")

echo "Packaging WebRTC: $PACKAGE_FILENAME"
package::prepare $PLATFORM $OUTDIR $PACKAGE_FILENAME "$CONFIGS"

echo Build successful
