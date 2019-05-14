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
   -b BRANCH      Latest revision on git branch. Overrides -r. Common branch names are 'branch-heads/nn', where 'nn' is the release number.
   -d DEPOT_TOOLS Location where depot_tools are installed.
   -v             Debug mode. Print all executed commands.
   -h             Show this message
EOF
}

while getopts :o:b:d:xDv OPTION; do
  case $OPTION in
  o) OUTDIR=$OPTARG ;;
  b) BRANCH=$OPTARG ;;
  d) DEPOT_TOOLS_DIR=$OPTARG ;;
  v) DEBUG=1 ;;
  ?) usage; exit 1 ;;
  esac
done

OUTDIR=${OUTDIR:-out}
BRANCH=${BRANCH:-}
DEBUG=${DEBUG:-0}
CONFIGS=${CONFIGS:-Debug Release}
PACKAGE_FILENAME_PATTERN=${PACKAGE_FILENAME_PATTERN:-"webrtc-%sr%-%to%-%tc%"}
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

if [ -z $BRANCH ]; then
  echo Please provide a branch to pull from
  exit 1
fi

REVISION=$(git ls-remote $REPO_URL --heads $BRANCH | head --lines 1 | cut --fields 1) || \
  { echo "Could not get branch revision" && exit 1; }

echo "Building branch: $BRANCH"

echo "Checking out WebRTC revision (this will take a while): $REVISION"
checkout $OUTDIR $REVISION

echo Checking WebRTC dependencies
check::webrtc::deps $PLATFORM $OUTDIR

echo Compiling WebRTC
compile $PLATFORM $OUTDIR "$TARGET_OS" "$TARGET_CPU" "$CONFIGS"

# Default PACKAGE_FILENAME is <projectname>-<short-rev-sha>-<target-os>-<target-cpu>
PACKAGE_FILENAME=$(interpret-pattern "$PACKAGE_FILENAME_PATTERN" "$TARGET_OS" "$TARGET_CPU" "$REVISION")

echo "Packaging WebRTC: $PACKAGE_FILENAME"
package::prepare $PLATFORM $OUTDIR $PACKAGE_FILENAME $DIR/resource "$CONFIGS"

echo Build successful
