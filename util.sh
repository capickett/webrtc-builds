# Detect the host platform.
# Set PLATFORM environment variable to override default behavior.
# Supported platform types - 'linux', 'win', 'mac'
# 'msys' is the git bash shell, built using mingw-w64, running under Microsoft
# Windows.
function detect-platform() {
  # set PLATFORM to android on linux host to build android
  case "$OSTYPE" in
  darwin*)      PLATFORM=${PLATFORM:-mac} ;;
  linux*)       PLATFORM=${PLATFORM:-linux} ;;
  win32*|msys*) PLATFORM=${PLATFORM:-win} ;;
  *)            echo "Building on unsupported OS: $OSTYPE"; exit 1; ;;
  esac
}

# Make sure depot tools are present.
#
# $1: The platform type.
# $2: The depot tools url.
# $3: The depot tools directory.
function check::depot-tools() {
  local depot_tools_dir="$1"

  if [ ! -d $depot_tools_dir ]; then
    echo "Could not find depot_tools at $depot_tools_dir"
    exit 1
  else
    pushd $depot_tools_dir >/dev/null
      git reset --hard -q
    popd >/dev/null
  fi
}

# Make sure a package is installed. Depends on sudo to be installed first.
#
# $1: The name of the package
# $2: Existence check binary. Defaults to name of the package.
function ensure-package() {
  local name="$1"
  local binary="${2:-$1}"
  if ! which $binary > /dev/null ; then
    sudo apt-get update -qq
    sudo apt-get install -y $name
  fi
}

# Make sure all build dependencies are present and platform specific
# environment variables are set.
#
# $1: The platform type.
function check::build::env() {
  local platform="$1"
  local target_cpu="$2"

  case $platform in
  mac)
    # for GNU version of cp: gcp
    which gcp || brew install coreutils
    ;;
  linux)
    if ! grep -v \# /etc/apt/sources.list | grep -q multiverse ; then
      echo "*** Warning: The Multiverse repository is probably not enabled ***"
      echo "*** which is required for things like msttcorefonts.           ***"
    fi
    if ! which sudo > /dev/null ; then
      apt-get update -qq
      apt-get install -y sudo
    fi
    ensure-package curl
    ensure-package git
    ensure-package python
    ensure-package lbzip2
    ensure-package lsb-release lsb_release
    ;;
  esac
}

# Make sure all WebRTC build dependencies are present.
# $1: The platform type.
function check::webrtc::deps() {
  local platform="$1"
  local outdir="$2"

  case $platform in
  linux)
    # Automatically accepts ttf-mscorefonts EULA
    echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
    sudo $outdir/src/build/install-build-deps.sh --no-syms --no-arm --no-chromeos-fonts --no-nacl --no-prompt
    ;;
  esac
}

# Check out a specific revision.
#
# $1: The output directory.
# $2: Revision represented as a git SHA.
function checkout() {
  local outdir="$1"

  pushd $outdir >/dev/null
    # Fetch only the first-time, otherwise sync.
    if [ ! -d src ]; then
      echo Missing source directory
      exit 1
    fi

    # Remove all unstaged files that can break gclient sync
    # NOTE: need to redownload resources
    pushd src >/dev/null
      # git reset --hard
      git clean -f
    popd >/dev/null

    gclient sync --force
  popd >/dev/null
}

# Compile using ninja.
#
# $1 The output directory, 'out/$TARGET_CPU/Debug', or 'out/$TARGET_CPU/Release'
# $2 Additional gn arguments
function compile::ninja() {
  local outputdir="$1"
  local gn_args="$2"

  echo "Generating project files with: $gn_args"
  gn gen $outputdir --args="$gn_args"
  pushd $outputdir >/dev/null
    ninja -C  .
  popd >/dev/null
}

# Compile the libraries.
#
# $1: The platform type.
# $2: The output directory.
function compile() {
  local platform="$1"
  local outdir="$2"
  local target_os="$3"
  local target_cpu="$4"
  local configs="$5"

  # Set default default common and target args.
  # `rtc_include_tests=false`: Disable all unit tests
  # `treat_warnings_as_errors=false`: Don't error out on compiler warnings
  local common_args="rtc_include_tests=false treat_warnings_as_errors=false"
  local target_args="target_os=\"$target_os\" target_cpu=\"$target_cpu\""

  # Build WebRTC with RTII enbled.
  common_args+=" use_rtti=true"

  # Disable examples.
  common_args+=" rtc_build_examples=false"

  # Disable building tools.
  common_args+=" rtc_build_tools=false"

  # Static vs Dynamic CRT: When `is_component_build` is false static CTR will be
  # enforced.By default Debug builds are dynamic and Release builds are static.
  common_args+=" is_component_build=false"

  # `enable_iterator_debugging=false`: Disable libstdc++ debugging facilities
  # unless all your compiled applications and dependencies define _GLIBCXX_DEBUG=1.
  # This will cause errors like: undefined reference to `non-virtual thunk to
  # cricket::VideoCapturer::AddOrUpdateSink(rtc::VideoSinkInterface<webrtc::VideoFrame>*,
  # rtc::VideoSinkWants const&)'
  common_args+=" enable_iterator_debugging=false"

  pushd $outdir/src >/dev/null
    for cfg in $configs; do
      [ "$cfg" = 'Release' ] && common_args+=' is_debug=false strip_debug_info=true symbol_level=0'
      compile::ninja "out/$target_cpu/$cfg" "$common_args $target_args"
    done
  popd >/dev/null
}

# Package a compiled build into an archive file in the output directory.
#
# $1: The platform type.
# $2: The output directory.
# $3: The package filename.
# $4: The project's resource dirctory.
# $5: The build configurations.
# $6: The revision number.
function package::prepare() {
  local platform="$1"
  local srcdir="$2"
  local outdir="$3"
  local package_filename="$4"
  local configs="$5"

  if [ $platform = 'mac' ]; then
    CP='gcp'
  else
    CP='cp'
  fi

  # Create directory structure
  mkdir -p $outdir/$package_filename/include

  pushd $srcdir/src >/dev/null
    # Copy header files, skip third_party dir
    find . -path './third_party' -prune -o -type f \( -name '*.h' \) -print | \
      xargs -I '{}' $CP --parent '{}' $outdir/$package_filename/include

    # Find and copy dependencies
    # The following build dependencies were excluded:
    # gflags, ffmpeg, openh264, openmax_dl, winsdk_samples, yasm
    find . -name '*.h' -o -name README -o -name LICENSE -o -name COPYING | \
      grep './third_party' | \
      grep -E 'abseil-cpp|boringssl|expat/files|jsoncpp/source/json|libjpeg|libjpeg_turbo|libsrtp|libyuv|libvpx|opus|protobuf|usrsctp/usrsctpout/usrsctpout' | \
      xargs -I '{}' $CP --parent '{}' $outdir/$package_filename/include
  popd >/dev/null

  # Find and copy libraries
  for cfg in $configs; do
    mkdir -p $outdir/$package_filename/lib/$TARGET_CPU/$cfg
    find $srcdir/src/out/$TARGET_CPU/$cfg -name '*.so' -o -name '*.dll' -o -name '*.lib' -o -name '*.a' -o -name '*.jar' | \
      grep -E 'webrtc\.|boringssl|protobuf|system_wrappers' | \
      xargs -I '{}' $CP '{}' $outdir/$package_filename/lib/$TARGET_CPU/$cfg
  done
}

# This interprets a pattern and returns the interpreted one.
# $1: The pattern.
# $2: The target os for cross-compilation.
# $3: The target cpu for cross-compilation.
# $4: The revision.
function interpret-pattern() {
  local pattern="$1"
  local target_os="$2"
  local target_cpu="$3"

  pattern=${pattern//%to%/$target_os}
  pattern=${pattern//%tc%/$target_cpu}

  echo "$pattern"
}

# Return the latest revision from the git repo.
#
# $1: The git repo URL
function latest-rev() {
  local repo_url="$1"
  git ls-remote $repo_url HEAD | cut -f1
}

# Return the associated revision number for a given git sha revision.
#
# $1: The git repo URL
# $2: The revision git sha string
function revision-number() {
  local repo_url="$1"
  local revision="$2"
  # This says curl the revision log with text format, base64 decode it using
  # openssl since its more portable than just 'base64', take the last line which
  # contains the commit revision number and output only the matching {#nnn} part
  openssl base64 -d -A <<< $(curl --silent $repo_url/+/$revision?format=TEXT) \
    | tail -1 | egrep -o '{#([0-9]+)}' | tr -d '{}#'
}

# Return a short revision sha.
#
# $1: The revision string
function short-rev() {
  local revision="$1"
  echo $revision | cut -c -7
}