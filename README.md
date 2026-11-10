# nebula-base

Base docker image for nebula worker is based on Debian Trixie with Python 3.13

Contains media processing dependencies such as:

 - ffmpeg
 - libmxf / libbmx
 - MLT framework and melt

## Hardware encoding

ffmpeg is built with both NVENC and VAAPI support.

**NVENC** requires the NVIDIA container toolkit on the host:

```
docker run --runtime=nvidia --gpus all ...
```

**VAAPI** requires the DRI render node to be passed to the container.
The image ships with `intel-media-va-driver` (Intel) and `mesa-va-drivers` (AMD):

```
docker run --device /dev/dri ...
```

## Testing

`make test` runs `test.sh` inside the image and checks that ffmpeg, bmx tools
and melt work. Hardware encoding is tested only when the device is available
in the container:

```
make test
make test DOCKER_ARGS="--device /dev/dri"
make test DOCKER_ARGS="--runtime=nvidia --gpus all"
```
