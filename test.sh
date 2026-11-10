#!/bin/bash
#
# Smoke test for the nebula-worker-base image.
# Runs inside the container (see `make test`):
#
#   docker run --rm -v ./test.sh:/test.sh:ro <image> bash /test.sh
#
# Hardware encoding tests (NVENC / VAAPI) are executed only when
# the corresponding device is available in the container, otherwise
# only the presence of the encoders in the ffmpeg build is verified.
#

set -u

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR" || exit 1

PASSED=0
FAILED=0
SKIPPED=0

pass() { PASSED=$((PASSED + 1)); echo "[ OK ] $1"; }
skip() { SKIPPED=$((SKIPPED + 1)); echo "[SKIP] $1"; }
fail() {
  FAILED=$((FAILED + 1))
  echo "[FAIL] $1"
  [ -f "$WORKDIR/last.log" ] && tail -n 15 "$WORKDIR/last.log" | sed 's/^/       /'
}

# run <description> <command...>
# Passes when the command exits with zero status.
run() {
  local desc=$1
  shift
  if "$@" >"$WORKDIR/last.log" 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# has <description> <needle> <command...>
# Passes when the command output contains a line matching the needle.
has() {
  local desc=$1 needle=$2
  shift 2
  if "$@" 2>&1 | grep -Eq -- "$needle"; then
    pass "$desc"
  else
    echo "no match for '$needle' in the output of: $*" >"$WORKDIR/last.log"
    fail "$desc"
  fi
}

# probe <file> <stream> <entry> - print a single stream property
probe() {
  ffprobe -v error -select_streams "$2" -show_entries "stream=$3" \
    -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1
}

# expect <description> <expected> <actual>
expect() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    echo "expected '$2', got '$3'" >"$WORKDIR/last.log"
    fail "$1"
  fi
}

section() { echo; echo "== $1"; }

FF="ffmpeg -hide_banner -nostdin -loglevel error -y"
SRC_V="testsrc2=size=1920x1080:rate=25:duration=2"
SRC_A="sine=frequency=1000:sample_rate=48000:duration=2"

#
# Shared libraries
#

section "Shared libraries"

check_libs() {
  local missing
  missing=$(
    find /usr/local/bin /usr/local/lib -type f \( -perm -u+x -o -name '*.so*' \) \
      -exec ldd {} + 2>/dev/null | grep 'not found' | sort -u
  )
  [ -z "$missing" ] || { echo "$missing"; return 1; }
}
run "all libraries in /usr/local resolve" check_libs

#
# FFmpeg
#

section "FFmpeg"

run "ffmpeg runs" ffmpeg -hide_banner -version
run "ffprobe runs" ffprobe -hide_banner -version
has "ffmpeg is the NEBULA build" 'ffmpeg version [^ ]*-?NEBULA' ffmpeg -version

for enc in libx264 libx265 libvpx-vp9 libsvtav1 libmp3lame libvorbis \
  mpeg2video dnxhd prores_ks \
  h264_nvenc hevc_nvenc av1_nvenc \
  h264_vaapi hevc_vaapi av1_vaapi mpeg2_vaapi vp9_vaapi; do
  has "encoder $enc" "^ [VAS][^ ]* +$enc " ffmpeg -hide_banner -encoders
done

for dec in h264_cuvid hevc_cuvid libdav1d; do
  has "decoder $dec" "^ [VAS][^ ]* +$dec " ffmpeg -hide_banner -decoders
done

for hw in cuda vaapi; do
  has "hwaccel $hw" "^$hw\$" ffmpeg -hide_banner -hwaccels
done

for flt in drawtext subtitles zscale ocio scale_vaapi deinterlace_vaapi; do
  has "filter $flt" "^ [^ ]+ +$flt " ffmpeg -hide_banner -filters
done

for proto in srt https; do
  has "protocol $proto" "^ *$proto\$" ffmpeg -hide_banner -protocols
done

run "encode h264/aac mp4" \
  $FF -f lavfi -i "$SRC_V" -f lavfi -i "$SRC_A" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest h264.mp4
expect "mp4 video codec" h264 "$(probe h264.mp4 v:0 codec_name)"
expect "mp4 video size" 1920 "$(probe h264.mp4 v:0 width)"
expect "mp4 audio codec" aac "$(probe h264.mp4 a:0 codec_name)"

run "encode hevc" \
  $FF -f lavfi -i "$SRC_V" -c:v libx265 -preset ultrafast -x265-params log-level=error hevc.mp4
run "encode av1 (svt)" \
  $FF -f lavfi -i "$SRC_V" -c:v libsvtav1 -preset 12 -svtav1-params lp=2 av1.mp4
run "decode av1 (dav1d)" \
  $FF -c:v libdav1d -i av1.mp4 -frames:v 5 -f null -
run "scale using zscale" \
  $FF -i h264.mp4 -vf zscale=w=640:h=360 -frames:v 5 -f null -

FONT=$(find /usr/share/fonts /usr/local/share/fonts -iname '*.ttf' 2>/dev/null | head -n 1)
if [ -n "$FONT" ]; then
  run "render text using drawtext" \
    $FF -i h264.mp4 -vf "drawtext=fontfile=$FONT:text=nebula:fontsize=48" -frames:v 5 -f null -
else
  skip "render text using drawtext (no font in the image)"
fi

#
# Hardware encoding
#

section "Hardware encoding"

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  run "encode h264_nvenc" \
    $FF -f lavfi -i "$SRC_V" -c:v h264_nvenc nvenc_h264.mp4
  run "encode hevc_nvenc" \
    $FF -f lavfi -i "$SRC_V" -c:v hevc_nvenc nvenc_hevc.mp4
  run "decode using cuda hwaccel" \
    $FF -hwaccel cuda -i nvenc_h264.mp4 -f null -
else
  skip "nvenc encoding (no NVIDIA GPU in the container, use --gpus all)"
fi

VAAPI_DEVICE=${VAAPI_DEVICE:-$(ls /dev/dri/renderD* 2>/dev/null | head -n 1)}
if [ -n "$VAAPI_DEVICE" ] && vainfo --display drm --device "$VAAPI_DEVICE" >vainfo.log 2>&1; then
  run "vainfo" cat vainfo.log
  if grep -q 'H264.*VAEntrypointEncSlice' vainfo.log; then
    run "encode h264_vaapi" \
      $FF -vaapi_device "$VAAPI_DEVICE" -f lavfi -i "$SRC_V" \
      -vf format=nv12,hwupload -c:v h264_vaapi vaapi_h264.mp4
    expect "h264_vaapi output codec" h264 "$(probe vaapi_h264.mp4 v:0 codec_name)"
    run "decode using vaapi hwaccel" \
      $FF -hwaccel vaapi -hwaccel_device "$VAAPI_DEVICE" -i vaapi_h264.mp4 -f null -
  else
    skip "h264_vaapi encoding (not supported by $VAAPI_DEVICE)"
  fi
  if grep -q 'HEVCMain .*VAEntrypointEncSlice' vainfo.log; then
    run "encode hevc_vaapi" \
      $FF -vaapi_device "$VAAPI_DEVICE" -f lavfi -i "$SRC_V" \
      -vf format=nv12,hwupload -c:v hevc_vaapi vaapi_hevc.mp4
  else
    skip "hevc_vaapi encoding (not supported by $VAAPI_DEVICE)"
  fi
else
  skip "vaapi encoding (no usable render node, use --device /dev/dri)"
fi

#
# BMX
#

section "BMX tools"

for tool in raw2bmx bmxtranswrap mxf2raw bmxparse; do
  run "$tool runs" "$tool" --version
done

run "create avc essence" \
  $FF -f lavfi -i "$SRC_V" -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -x264-params aud=1:keyint=25 -bsf:v h264_mp4toannexb -f h264 video.h264
run "create pcm essence" \
  $FF -f lavfi -i "$SRC_A" -ac 2 -c:a pcm_s16le audio.wav

run "raw2bmx: wrap op1a mxf" \
  raw2bmx -t op1a -f 25 -o op1a.mxf --avc video.h264 --wave audio.wav
has "mxf2raw: read mxf info" 'AVC|H.?264' mxf2raw --info op1a.mxf
run "bmxtranswrap: rewrap to rdd9" \
  bmxtranswrap -t op1a -o rewrap.mxf op1a.mxf
expect "ffprobe: mxf video codec" h264 "$(probe rewrap.mxf v:0 codec_name)"
expect "ffprobe: mxf audio codec" pcm_s16le "$(probe rewrap.mxf a:0 codec_name)"
run "ffmpeg: decode bmx mxf" $FF -i rewrap.mxf -f null -

run "ffmpeg: create xdcam hd422 mxf" \
  $FF -f lavfi -i "$SRC_V" -f lavfi -i "$SRC_A" \
  -c:v mpeg2video -pix_fmt yuv422p -b:v 50M -minrate 50M -maxrate 50M -bufsize 17825792 \
  -rc_init_occupancy 17825792 -g 12 -bf 2 -flags +ildct+ilme \
  -c:a pcm_s24le -ar 48000 -shortest -f mxf xdcam.mxf
has "mxf2raw: read ffmpeg mxf" 'MPEG' mxf2raw --info xdcam.mxf

#
# MLT
#

section "MLT"

run "melt runs" melt -version

check_melt_modules() {
  local out
  out=$(melt -query consumers 2>&1)
  if echo "$out" | grep -q 'failed to dlopen'; then
    echo "$out" | grep -A1 'failed to dlopen'
    return 1
  fi
}
run "all melt modules load" check_melt_modules

has "melt avformat consumer" '^ +- avformat$' melt -query consumers
has "melt avformat producer" '^ +- avformat$' melt -query producers
has "melt xml consumer" '^ +- xml$' melt -query consumers

run "melt: render h264 mp4" \
  melt -silent -profile atsc_1080p_25 color:red out=24 h264.mp4 out=24 \
  -consumer avformat:melt.mp4 vcodec=libx264 preset=ultrafast acodec=aac real_time=-1
expect "melt output codec" h264 "$(probe melt.mp4 v:0 codec_name)"
expect "melt output size" 1920 "$(probe melt.mp4 v:0 width)"
expect "melt output frames" 50 \
  "$(ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames -of default=nw=1:nk=1 melt.mp4 2>/dev/null)"

cat >mlt_test.py <<'EOF'
import mlt7 as mlt

mlt.Factory().init()
profile = mlt.Profile("atsc_1080p_25")
producer = mlt.Producer(profile, "h264.mp4")
assert producer.is_valid(), "producer is not valid"
assert producer.get_length() == 50, f"unexpected length {producer.get_length()}"
frame = producer.get_frame()
assert frame.get_image(mlt.mlt_image_rgb, 1920, 1080), "unable to get image"
print("mlt", mlt.mlt_version_get_string())
EOF
run "python: mlt7 bindings" python3 mlt_test.py

#
# Summary
#

echo
echo "passed: $PASSED, failed: $FAILED, skipped: $SKIPPED"
[ "$FAILED" -eq 0 ]
