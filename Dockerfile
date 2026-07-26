FROM debian:trixie-slim AS base

RUN \
  apt-get update \
  && apt-get -y upgrade \
  && apt-get install -yqq --no-install-recommends \
    cifs-utils \
    curl \
    mediainfo \
    procps \
    python3 \
    python3-pip \
    python-is-python3 \
    wget \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

#
# Build base
#

FROM base AS build

RUN \
  apt-get update \
  && apt-get install -yqq --no-install-recommends \
    apt-utils \
    autoconf \
    automake \
    build-essential \
    cmake \
    g++ \
    git \
    intltool \
    libexpat1-dev \
    libtool \
    liburiparser-dev \
    meson \
    nasm \
    ninja-build \
    pkg-config \
    python3-dev \
    swig \
    uuid-dev \
    unzip \
    yasm \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

#
# BMX
#

FROM build AS bmx

RUN mkdir /src
WORKDIR /src

# Pinning specific commits/tags is recommended for reproducible builds.
RUN git clone https://github.com/Limecraft/ebu-libmxf \
  && git clone https://github.com/Limecraft/ebu-libmxfpp \
  && git clone https://github.com/Limecraft/ebu-bmx

WORKDIR /src/ebu-libmxf
RUN ./autogen.sh && ./configure --prefix=/usr/local \
  && make -j$(nproc) && make install && make install DESTDIR=/dist && /sbin/ldconfig

WORKDIR /src/ebu-libmxfpp
RUN ./autogen.sh && ./configure --prefix=/usr/local \
  && make -j$(nproc) && make install && make install DESTDIR=/dist && /sbin/ldconfig

WORKDIR /src/ebu-bmx
RUN ./autogen.sh && ./configure --prefix=/usr/local \
  && make -j$(nproc) && make install && make install DESTDIR=/dist && /sbin/ldconfig

#
# FFMPEG & MLT
#

FROM build AS ffmpeg

ENV FFMPEG_VERSION=8.1.2
ENV MLT_VERSION=7.40.0
ENV LD_LIBRARY_PATH=/usr/local/lib

RUN apt-get update && apt-get install -yqq --no-install-recommends \
  ladspa-sdk \
  libarchive-dev \
  libass-dev \
  libdav1d-dev \
  libebur128-dev \
  libegl1-mesa-dev \
  libeigen3-dev \
  libexif-dev \
  libffmpeg-nvenc-dev \
  libfreetype-dev \
  libfftw3-dev \
  libgavl-dev \
  libgcrypt20-dev \
  libgdk-pixbuf-2.0-dev \
  libgnutls-openssl-dev \
  libharfbuzz-dev \
  libmp3lame-dev \
  libopencolorio-dev \
  libsamplerate-dev \
  libsoup2.4-dev \
  libsox-dev \
  libsoxr-dev \
  libsrt-gnutls-dev \
  libsvtav1enc-dev \
  libtheora-dev \
  libvdpau-dev \
  libvorbis-dev \
  libvpx-dev \
  libx264-dev \
  libx265-dev \
  libxml2-dev \
  libzimg-dev \
  xutils-dev \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# FFMPEG
WORKDIR /src
RUN \
  wget http://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz \
  && tar -xzf ffmpeg-${FFMPEG_VERSION}.tar.gz \
  && rm ffmpeg-${FFMPEG_VERSION}.tar.gz \
  && mv ffmpeg-${FFMPEG_VERSION} ffmpeg

# Build FFMPEG
WORKDIR /src/ffmpeg
RUN \
  ./configure \
    --prefix=/usr/local \
    --disable-doc \
    --disable-ffplay \
    --disable-alsa \
    --enable-gpl \
    --enable-version3 \
    --enable-nonfree \
    --enable-shared \
    --enable-pthreads \
    --enable-gnutls \
    --enable-libfreetype \
    --enable-libharfbuzz \
    --enable-libmp3lame \
    --enable-libopencolorio \
    --enable-libtheora \
    --enable-libvorbis \
    --enable-libsoxr \
    --enable-libvpx \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libass \
    --enable-libzimg \
    --enable-libsrt \
    --enable-libdav1d \
    --enable-libsvtav1 \
    --enable-nvenc \
    --enable-nvdec \
    --extra-version=NEBULA \
    --enable-runtime-cpudetect \
  && make -j$(nproc) \
  && make install \
  && make install DESTDIR=/dist

# MLT
WORKDIR /src
RUN \
  wget https://github.com/mltframework/mlt/archive/refs/tags/v${MLT_VERSION}.tar.gz \
  && tar -xzf v${MLT_VERSION}.tar.gz \
  && rm v${MLT_VERSION}.tar.gz \
  && mv mlt-${MLT_VERSION} mlt

# Build MLT
WORKDIR /src/mlt
RUN cmake -GNinja \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DBUILD_TESTS_WITH_QT6=OFF \
  -DMOD_FREI0R=OFF \
  -DMOD_DECKLINK=OFF \
  -DMOD_JACKRACK=OFF \
  -DMOD_KDENLIVE=OFF \
  -DMOD_NDI=OFF \
  -DMOD_OLDFILM=OFF \
  -DMOD_QT6=OFF \
  -DMOD_MOVIT=OFF \
  -DMOD_RTAUDIO=OFF \
  -DMOD_RUBBERBAND=OFF \
  -DMOD_GDK=OFF \
  -DMOD_SDL=OFF \
  -DMOD_SDL1=OFF \
  -DMOD_SDL2=OFF \
  -DMOD_VIDSTAB=OFF \
  -DMOD_RNNOISE=OFF \
  -DSWIG_PYTHON=ON \
  . \
  && cmake --build . \
  && cmake --install . \
  && DESTDIR=/dist cmake --install .

#
# Final image
#

FROM base

ENV PYTHONUNBUFFERED=1
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

# Install runtime dependencies
RUN \
  apt-get update \
  && apt-get install -yqq --no-install-recommends \
    amb-plugins \
    libass9 \
    libdav1d7 \
    libebur128-1 \
    libexif12 \
    libexpat1 \
    libfftw3-bin \
    libfreetype6 \
    libgcrypt20 \
    libgnutls-openssl27 \
    libgdk-pixbuf-2.0-0 \
    libharfbuzz0b \
    libmp3lame0 \
    libopencolorio2.1 \
    libsamplerate0 \
    libsndio7.0 \
    libsrt1.5-gnutls \
    libsox3 \
    libsoxr0 \
    libsvtav1enc2 \
    libtheora0 \
    liburiparser1 \
    libvdpau1 \
    libvorbis0a \
    libvorbisenc2 \
    libvpx9 \
    libx264-164 \
    libx265-215 \
    libxv1 \
    libxml2 \
    libzimg2 \
    uuid \
    zlib1g-dev \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Copy built files cleanly from the staging directory (/dist)
COPY --from=ffmpeg /dist/usr/local/ /usr/local/
COPY --from=bmx /dist/usr/local/ /usr/local/

# Fix Python site-packages path for MLT Python bindings
RUN if [ -f /usr/local/lib/python3/dist-packages/mlt7.py ]; then \
      mkdir -p /usr/local/lib/python3.13/site-packages && \
      ln -s /usr/local/lib/python3/dist-packages/mlt7.py /usr/local/lib/python3.13/site-packages/mlt.py && \
      ln -s /usr/local/lib/python3/dist-packages/_mlt7.so /usr/local/lib/python3.13/site-packages/_mlt7.so && \
      ln -s /usr/local/lib/python3/dist-packages/mlt7.py /usr/local/lib/python3.13/site-packages/mlt7.py && \
      ln -s /usr/local/lib/python3/dist-packages/_mlt7.so /usr/local/lib/python3.13/site-packages/_mlt7.so; \
    fi

WORKDIR /app

RUN ldconfig
