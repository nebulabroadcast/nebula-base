FROM python:3.13-slim-trixie AS base

RUN apt-get update && apt-get -y upgrade && apt-get install -yqq \
    cifs-utils \
    curl \
    mediainfo \
    wget

#
# Build base
#

FROM base AS build

RUN apt-get install -yqq \
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
  yasm

#
# BMX
#

FROM build AS bmx

RUN mkdir /src
RUN mkdir /dist

WORKDIR /src

RUN git clone https://github.com/Limecraft/ebu-libmxf
RUN git clone https://github.com/Limecraft/ebu-libmxfpp
RUN git clone https://github.com/Limecraft/ebu-bmx

WORKDIR /src/ebu-libmxf
RUN ./autogen.sh && ./configure && make && make install && /sbin/ldconfig

WORKDIR /src/ebu-libmxfpp
RUN ./autogen.sh && ./configure && make && make install && /sbin/ldconfig

WORKDIR /src/ebu-bmx
RUN ./autogen.sh && ./configure && make && make install && /sbin/ldconfig

RUN cp -r /usr/local/lib /dist/
RUN cp -r /usr/local/bin /dist/
RUN rm -rf /dist/lib/pkgconfig /dist/python*
WORKDIR /dist

#
# FFMPEG
#

FROM build AS ffmpeg

ENV FFMPEG_VERSION=8.1.2
ENV MLT_VERSION=7.40.0
ENV LD_LIBRARY_PATH=/usr/local/lib

RUN apt-get update 

RUN apt-get install -yqq \
  ladspa-sdk \
  libarchive-dev \
  libebur128-dev \
  libegl1-mesa-dev \
  libeigen3-dev \
  libexif-dev \
  libfftw3-dev \
  libgavl-dev \
  libgcrypt20-dev \
  libgdk-pixbuf-2.0-dev \
  libgnutls-openssl-dev \
  libmp3lame-dev \
  libsamplerate-dev \
  libsamplerate0-dev \
  libsoup2.4-dev \
  libsox-dev \
  libtheora-dev \
  libvdpau-dev \
  libvorbis-dev \
  libvpx-dev \
  libx264-dev \
  libxml2-dev \
  xutils-dev

WORKDIR /src

# FFMPEG

RUN \
  wget http://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz \
  && tar -xzf ffmpeg-${FFMPEG_VERSION}.tar.gz \
  && rm ffmpeg-${FFMPEG_VERSION}.tar.gz \
  && mv ffmpeg-${FFMPEG_VERSION} ffmpeg

# MLT

RUN \
  wget https://github.com/mltframework/mlt/archive/refs/tags/v${MLT_VERSION}.tar.gz \
  && tar -xzf v${MLT_VERSION}.tar.gz \
  && rm v${MLT_VERSION}.tar.gz \
  && mv mlt-${MLT_VERSION} mlt


# Build FFMPEG

WORKDIR /src/ffmpeg
RUN ./configure \
  --prefix=/usr/local \
  --disable-doc \
  --enable-gpl \
  --enable-version3 \
  --enable-shared \
  --enable-debug \
  --enable-pthreads \
  --enable-libmp3lame \
  --enable-libtheora \
  --enable-libvorbis \
  --enable-libvpx \
  --enable-libx264 \
  --enable-gnutls \
  --extra-version=NEBULA \
  --enable-runtime-cpudetect && make -j16 && make install

# Build MLT

WORKDIR /src/mlt
RUN cmake -GNinja \
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
  -DMOD_MOVIT=OFF \
  -DMOD_GDK=OFF \
  -DMOD_SDL=OFF \
  -DMOD_SDL1=OFF \
  -DMOD_SDL2=OFF \
  -DMOD_VIDSTAB=OFF \
  -DMOD_RNNOISE=OFF \
  -DSWIG_PYTHON=ON \
  . \
  && cmake --build . \
  && cmake --install . --prefix /usr/local


#
# Final image
#

FROM base

ENV PYTHONUNBUFFERED=1

# Install runtime dependencies
# Build essentials are needed for building some python packages

RUN apt-get install -yqq \
    amb-plugins \
    libebur128-1 \
    libexif12 \
    libexpat1 \
    libfftw3-bin \
    libgcrypt20 \
    libgnutls-openssl27 \
    libgdk-pixbuf-2.0-0 \
    libmp3lame0 \
    libsamplerate0 \
    libsndio7.0 \
    libsox3 \
    libtheora0 \
    liburiparser1 \
    libvdpau1 \
    libvorbis0a \
    libvorbisenc2 \
    libvpx9 \
    libx264-164 \
    libxv1 \
    libxml2 \
    uuid \
    zlib1g-dev \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

#
# Copy built files
#

COPY --from=ffmpeg /usr/local/ /usr/local/

COPY --from=bmx /dist/lib /usr/local/lib
COPY --from=bmx /dist/bin /usr/local/bin

# RUN cp /usr/local/lib/python3/dist-packages/mlt7.py /usr/local/lib/python3.12/site-packages/mlt.py
# RUN cp /usr/local/lib/python3/dist-packages/_mlt7.so /usr/local/lib/python3.12/site-packages/_mlt7.so

RUN ldconfig
