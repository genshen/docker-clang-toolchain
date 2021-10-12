ARG ALPINE_VERSION=3.13.5
ARG LLVM_VERSION=12.0.0
ARG INSTALL_PREFIX=/usr/local
ARG LIBUNWIND_INSTALL_PATH=${INSTALL_PREFIX}/libunwind
ARG LIBCXXABI_INSTALL_PATH=${INSTALL_PREFIX}/libcxxabi
ARG LIBCXX_INSTALL_PATH=${INSTALL_PREFIX}/libcxx
ARG CLANG_INSTALL_PATH=${INSTALL_PREFIX}/clang/

FROM alpine:${ALPINE_VERSION} AS builder_env

ARG LLVM_VERSION
ENV LLVM_DOWNLOAD_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz"
ENV LLVM_SRC_DIR=/llvm_src
ARG INSTALL_PREFIX
ENV INSTALL_PREFIX=${INSTALL_PREFIX}

## install packages and download source.
RUN wget ${LLVM_DOWNLOAD_URL} -O /tmp/llvmorg.tar.xz \
    && mkdir -p ${LLVM_SRC_DIR} \
    && tar -C ${LLVM_SRC_DIR} --strip-components 1 -Jxf /tmp/llvmorg.tar.xz \
    && rm /tmp/llvmorg.tar.xz

RUN apk add --no-cache build-base wget cmake python3 ninja linux-headers

## build clang with compiler-rt support
# but clang/clang++ binary is still linked to GNU libs.
FROM builder_env AS clang-gnu

ARG LLVM_VERSION
ENV LIBUNWIND_GNU_INSTALL_PATH=${INSTALL_PREFIX}/gnu-libunwind
ENV LIBCXXABI_GNU_INSTALL_PATH=${INSTALL_PREFIX}/gnu-libcxxabi
ENV LIBCXX_GNU_INSTALL_PATH=${INSTALL_PREFIX}/gnu-libcxx
ENV CLANG_GNU_INSTALL_PATH=${INSTALL_PREFIX}/gnu-clang/${LLVM_VERSION}

RUN mkdir -p ${INSTALL_PREFIX}/lib ${INSTALL_PREFIX}/bin ${INSTALL_PREFIX}/include

# build libunwind
RUN cd ${LLVM_SRC_DIR}/libunwind \
    && cmake -B./build -H./ \
        -DCMAKE_INSTALL_PREFIX=${LIBUNWIND_GNU_INSTALL_PATH} \
        -DLIBUNWIND_ENABLE_SHARED=ON \
        -DLLVM_PATH=../llvm \
        -DCMAKE_C_FLAGS="-fPIC" \
        -DCMAKE_CXX_FLAGS="-fPIC" \
    && cmake --build ./build --target install \
    && rm build -rf \
    && cd ../  \
    && ln -s ${LIBUNWIND_GNU_INSTALL_PATH}/lib/* ${INSTALL_PREFIX}/lib/

## build libc++abi
RUN cd ${LLVM_SRC_DIR}/libcxxabi \
    &&  cmake -B./build -H./ \
        -DCMAKE_INSTALL_PREFIX=${LIBCXXABI_GNU_INSTALL_PATH} \
        -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_LIBUNWIND_PATH=../libunwind \
        -DLIBCXXABI_LIBCXX_INCLUDES=../libcxx/include \
        -DLLVM_PATH=../llvm \
    && cmake --build ./build --target install \
    && rm build -rf \
    && cd ../  \
    && ln -s ${LIBCXXABI_GNU_INSTALL_PATH}/lib/* ${INSTALL_PREFIX}/lib/

## build libcxx
RUN cd ${LLVM_SRC_DIR}/libcxx \
    &&  cmake -B./build -H./ -G Ninja \
        -DCMAKE_INSTALL_PREFIX=${LIBCXX_GNU_INSTALL_PATH} \
        -DLIBCXX_ENABLE_SHARED=ON -DLIBCXX_ENABLE_STATIC=ON  \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_HAS_GCC_S_LIB=OFF \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_CXX_ABI_INCLUDE_PATHS=../libcxxabi/include \
        -DLLVM_PATH=../llvm \
    && cmake --build ./build --target install \
    && rm build -rf \
    && cd ../ \
    && ln -s ${LIBCXX_GNU_INSTALL_PATH}/lib/* ${INSTALL_PREFIX}/lib/ \
    && ln -s ${LIBCXX_GNU_INSTALL_PATH}/include/* ${INSTALL_PREFIX}/include/

# clang will be linked to libstdc++ and libgcc (not libcxx,libcxxabi, libunwind)
RUN cd ${LLVM_SRC_DIR}/ \
    && cmake -B./llvm-build-with-compiler-rt -H./llvm -DCMAKE_BUILD_TYPE=MinSizeRel -G Ninja \
        -DCMAKE_INSTALL_PREFIX=${CLANG_GNU_INSTALL_PATH} \
        -DLLVM_ENABLE_PROJECTS="clang;compiler-rt" \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=OFF \
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_BUILD_MEMPROF=OFF \
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-linux-musl \
    && cmake --build ./llvm-build-with-compiler-rt --target install \
    && rm llvm-build-with-compiler-rt -rf

## set cc and cxx compiler.
ENV CC=${CLANG_GNU_INSTALL_PATH}/bin/clang
ENV CXX=${CLANG_GNU_INSTALL_PATH}/bin/clang++


# libcxx and libunwind support,
# bootstrap building (buildiing libunwind, libcxx, libcxxabi using clang)
FROM clang-gnu AS clang-libs

ARG LIBUNWIND_INSTALL_PATH
ARG LIBCXXABI_INSTALL_PATH
ARG LIBCXX_INSTALL_PATH
ARG CLANG_INSTALL_PATH

# update libunwind which is compiled by clang
RUN cd ${LLVM_SRC_DIR}/libunwind \
    &&  cmake -B./build -H./ \
        -DCMAKE_INSTALL_PREFIX=${LIBUNWIND_INSTALL_PATH} \
        -DLIBUNWIND_ENABLE_SHARED=ON \
        -DLLVM_PATH=../llvm \
        -DCMAKE_C_FLAGS="-fPIC" \
        -DCMAKE_CXX_FLAGS="-fPIC" \
    && cmake --build ./build --target install \
    && rm build -rf \
    && cd ../  \
    && ln -snf ${LIBUNWIND_INSTALL_PATH}/lib/* ${INSTALL_PREFIX}/lib/

## build libc++abi
RUN cd ${LLVM_SRC_DIR}/libcxxabi \
    && cmake -B./build -H./ \
        -DCMAKE_INSTALL_PREFIX=${LIBCXXABI_INSTALL_PATH} \
        -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_LIBUNWIND_PATH=../libunwind \
        -DLIBCXXABI_LIBCXX_INCLUDES=../libcxx/include \
        -DLLVM_PATH=../llvm \
    && cmake --build ./build --target install \
    && rm build -rf \
    && cd ../   \
    && ln -snf ${LIBCXXABI_INSTALL_PATH}/lib/* ${INSTALL_PREFIX}/lib/

## build libcxx
RUN cd ${LLVM_SRC_DIR}/libcxx \
    &&  cmake -B./build -H./ -G Ninja \
        -DCMAKE_INSTALL_PREFIX=${LIBCXX_INSTALL_PATH} \
        -DLIBCXX_ENABLE_SHARED=ON -DLIBCXX_ENABLE_STATIC=ON  \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_HAS_GCC_S_LIB=OFF \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_CXX_ABI_INCLUDE_PATHS=../libcxxabi/include \
        -DLLVM_PATH=../llvm \
    && cmake --build ./build --target install \
    && rm build -rf \
    && cd ../ \
    && ln -snf ${LIBCXX_INSTALL_PATH}/lib/* ${INSTALL_PREFIX}/lib/ \
    && ln -snf ${LIBCXX_INSTALL_PATH}/include/* ${INSTALL_PREFIX}/include/

# build new clang with old gnu-clang,
# the new clang/clang++ binary will not be linked to GNU libs.
# todo add option of '-DLLVM_ENABLE_FFI'
FROM clang-libs AS clang-bootstrap

# reduce size: https://llvm.org/docs/BuildingADistribution.html#options-for-reducing-size
RUN cd ${LLVM_SRC_DIR}/ \
    && cmake -B./llvm-build-with-compiler-rt -H./llvm -DCMAKE_BUILD_TYPE=MinSizeRel -G Ninja \
        -DCMAKE_INSTALL_PREFIX=${CLANG_INSTALL_PATH} \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
        -DLLVM_ENABLE_PROJECTS="clang;compiler-rt" \
        -DLLVM_BUILD_LLVM_DYLIB=ON \
        -DLLVM_LINK_LLVM_DYLIB=ON \
        -DLLVM_ENABLE_LIBCXX=ON \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=ON \
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_BUILD_MEMPROF=OFF \
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-linux-musl  \
    && cmake --build ./llvm-build-with-compiler-rt --target install \
    && rm -rf llvm-build-with-compiler-rt

FROM alpine:${ALPINE_VERSION} AS clang-toolchain

LABEL maintainer="genshen genshenchu@gmail.com" \
    description="clang/clang++ toolchain without gnu."

ARG INSTALL_PREFIX
ARG LIBUNWIND_INSTALL_PATH
ARG LIBCXXABI_INSTALL_PATH
ARG LIBCXX_INSTALL_PATH
ARG CLANG_INSTALL_PATH

COPY --from=clang-bootstrap ${LIBUNWIND_INSTALL_PATH} ${LIBUNWIND_INSTALL_PATH}
COPY --from=clang-bootstrap ${LIBCXXABI_INSTALL_PATH} ${LIBCXXABI_INSTALL_PATH}
COPY --from=clang-bootstrap ${LIBCXX_INSTALL_PATH} ${LIBCXX_INSTALL_PATH}
COPY --from=clang-bootstrap ${CLANG_INSTALL_PATH} ${CLANG_INSTALL_PATH}

# make symbolic links
# musl-dev is used for C lib headers, link stdio.h
RUN mkdir -p ${INSTALL_PREFIX}/lib ${INSTALL_PREFIX}/bin ${INSTALL_PREFIX}/include \
    && ln -s ${LIBUNWIND_INSTALL_PATH}/lib/*             ${INSTALL_PREFIX}/lib/  \
    && ln -s ${LIBCXXABI_INSTALL_PATH}/lib/*             ${INSTALL_PREFIX}/lib/ \
    && ln -s ${LIBCXX_INSTALL_PATH}/lib/*                ${INSTALL_PREFIX}/lib/ \
    && ln -s ${LIBCXX_INSTALL_PATH}/include/*            ${INSTALL_PREFIX}/include/ \
    && ln -s ${CLANG_INSTALL_PATH}/bin/*                 ${INSTALL_PREFIX}/bin/  \
    && apk add --no-cache libatomic linux-headers musl-dev binutils \
    && mkdir -p /project

WORKDIR /project
