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
  local platform="$1"
  local depot_tools_url="$2"
  local depot_tools_dir="$3"

  if [ ! -d $depot_tools_dir ]; then
    git clone -q $depot_tools_url $depot_tools_dir
    if [ $platform = 'win' ]; then
      # run gclient.bat to get python
      pushd $depot_tools_dir >/dev/null
      ./gclient.bat
      popd >/dev/null
    fi
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

# Check if any of the arguments is executable (logical OR condition).
# Using plain "type" without any option because has-binary is intended
# to know if there is a program that one can call regardless if it is
# an alias, builtin, function, or a disk file that would be executed.
function has-binary () {
  type "$1" &> /dev/null ;
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
  local target_os="$3"

  case $platform in
  linux)
    # Automatically accepts ttf-mscorefonts EULA
    echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
    sudo $outdir/src/build/install-build-deps.sh --no-syms --no-arm --no-chromeos-fonts --no-nacl --no-prompt
    ;;
  esac

  if [ $target_os = 'android' ]; then
    sudo $outdir/src/build/install-build-deps-android.sh
  fi
}

# Check out a specific revision.
#
# $1: The target OS type.
# $2: The output directory.
# $3: Revision represented as a git SHA.
function checkout() {
  local target_os="$1"
  local outdir="$2"
  local revision="$3"

  pushd $outdir >/dev/null
  local prev_target_os=$(cat $outdir/.webrtcbuilds_target_os 2>/dev/null)
  if [[ -n "$prev_target_os" && "$target_os" != "$prev_target_os" ]]; then
    echo The target OS has changed. Refetching sources for the new target OS
    rm -rf src .gclient*
  fi

  # Fetch only the first-time, otherwise sync.
  if [ ! -d src ]; then
    case $target_os in
    android)
      yes | fetch --nohooks webrtc_android
      ;;
    ios)
      fetch --nohooks webrtc_ios
      ;;
    *)
      fetch --nohooks webrtc
      ;;
    esac
  fi

  # Remove all unstaged files that can break gclient sync
  # NOTE: need to redownload resources
  pushd src >/dev/null
  # git reset --hard
  git clean -f
  popd >/dev/null

  # Checkout the specific revision after fetch
  gclient sync --force --revision $revision

  # Cache the target OS
  echo $target_os > $outdir/.webrtcbuilds_target_os
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
  local outdir="$2"
  local package_filename="$3"
  local resource_dir="$4"
  local configs="$5"
  local revision_number="$6"

  if [ $platform = 'mac' ]; then
    CP='gcp'
  else
    CP='cp'
  fi

  pushd $outdir >/dev/null

    # Create directory structure
    mkdir -p $package_filename/include packages
    pushd src >/dev/null

      # Find and copy header files
      local header_source_dir=.

      # Copy header files, skip third_party dir
      find $header_source_dir -path './third_party' -prune -o -type f \( -name '*.h' \) -print | \
        xargs -I '{}' $CP --parents '{}' $outdir/$package_filename/include

      # Find and copy dependencies
      # The following build dependencies were excluded:
      # gflags, ffmpeg, openh264, openmax_dl, winsdk_samples, yasm
      find $header_source_dir -name '*.h' -o -name README -o -name LICENSE -o -name COPYING | \
        grep './third_party' | \
        grep -E 'boringssl|expat/files|jsoncpp/source/json|libjpeg|libjpeg_turbo|libsrtp|libyuv|libvpx|opus|protobuf|usrsctp/usrsctpout/usrsctpout' | \
        xargs -I '{}' $CP --parents '{}' $outdir/$package_filename/include

    popd >/dev/null

    # Find and copy libraries
    for cfg in $configs; do
      mkdir -p $package_filename/lib/$TARGET_CPU/$cfg
      pushd src/out/$TARGET_CPU/$cfg >/dev/null
        mkdir -p $outdir/$package_filename/lib/$TARGET_CPU/$cfg
        find . -name '*.so' -o -name '*.dll' -o -name '*.lib' -o -name '*.a' -o -name '*.jar' | \
          grep -E 'webrtc\.|boringssl|protobuf|system_wrappers' | \
          xargs -I '{}' $CP '{}' $outdir/$package_filename/lib/$TARGET_CPU/$cfg
      popd >/dev/null
    done

    # Create pkgconfig files on linux
    if [ $platform = 'linux' ]; then
      for cfg in $configs; do
        mkdir -p $package_filename/lib/$TARGET_CPU/$cfg/pkgconfig
        CONFIG=$cfg envsubst '$CONFIG' < $resource_dir/pkgconfig/libwebrtc_full.pc.in > \
          $package_filename/lib/$TARGET_CPU/$cfg/pkgconfig/libwebrtc_full.pc
      done
    fi

  popd >/dev/null
}

# This packages a compiled build into a archive file in the output directory.
# $1: The platform type.
# $2: The output directory.
# $3: The package filename.
function package::archive() {
  local platform="$1"
  local outdir="$2"
  local package_filename="$3"

  if [ $platform = 'win' ]; then
    OUTFILE=$package_filename.7z
  else
    OUTFILE=$package_filename.tar.gz #.tar.bz2
  fi

  pushd $outdir >/dev/null

    # Archive the package
    rm -f $OUTFILE
    pushd $package_filename >/dev/null
      if [ $platform = 'win' ]; then
        $TOOLS_DIR/win/7z/7z.exe a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on -ir!lib/$TARGET_CPU -ir!include -r ../packages/$OUTFILE
      else
        tar -czvf ../packages/$OUTFILE lib/$TARGET_CPU include
        # tar cvf - lib/$TARGET_CPU include | gzip --best > ../packages/$OUTFILE
        # zip -r $package_filename.zip $package_filename >/dev/null
      fi
    popd >/dev/null

  popd >/dev/null
}

# Build and merge the output manifest.
#
# $1: The platform type.
# $2: The output directory.
# $3: The package filename.
function package::manifest() {
  local platform="$1"
  local outdir="$2"
  local package_filename="$3"

  if [ $platform = 'win' ]; then
    OUTFILE=$package_filename.7z
  else
    OUTFILE=$package_filename.tar.gz
  fi

  mkdir -p $outdir/packages
  pushd $outdir/packages >/dev/null
    # Create a JSON manifest
    rm -f $package_filename.json
    cat << EOF > $package_filename.json
{
  "file": "$OUTFILE",
  "date": "$(current-rev-date)",
  "branch": "${BRANCH}",
  "revision": "${REVISION_NUMBER}",
  "sha": "${REVISION}",
  "crc": "$(file-crc $OUTFILE)",
  "target_os": "${TARGET_OS}",
  "target_cpu": "${TARGET_CPU}"
}
EOF

  popd >/dev/null
}

# This interprets a pattern and returns the interpreted one.
# $1: The pattern.
# $2: The output directory.
# $3: The platform type.
# $4: The target os for cross-compilation.
# $5: The target cpu for cross-compilation.
# $6: The branch.
# $7: The revision.
# $8: The revision number.
function interpret-pattern() {
  local pattern="$1"
  local platform="$2"
  local outdir="$3"
  local target_os="$4"
  local target_cpu="$5"
  local branch="$6"
  local revision="$7"
  local revision_number="$8"
  local debian_arch="$(debian-arch $target_cpu)"
  local short_revision="$(short-rev $revision)"

  pattern=${pattern//%p%/$platform}
  pattern=${pattern//%to%/$target_os}
  pattern=${pattern//%tc%/$target_cpu}
  pattern=${pattern//%b%/$branch}
  pattern=${pattern//%r%/$revision}
  pattern=${pattern//%rn%/$revision_number}
  pattern=${pattern//%da%/$debian_arch}
  pattern=${pattern//%sr%/$short_revision}

  echo "$pattern"
}

# Return the latest revision date from the current git repo.
function current-rev-date() {
  git log -1 --format=%cd
}

# Return the latest revision from the git repo.
#
# $1: The git repo URL
function file-crc() {
  local file_path="$1"
   md5sum $file_path | grep -o '^\S*'
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

# This returns a short revision sha.
# $1: The target cpu for cross-compilation.
function debian-arch() {
  local target_cpu="$1"
  # set PLATFORM to android on linux host to build android
  case "$target_cpu" in
  x86*)         echo "i386" ;;
  x64*)         echo "amd64" ;;
  *)            echo "$target_cpu" ;;
  esac
}
