FROM alpine:3.13.5 AS builder_env

ARG REQUIRE="build-base wget cmake python3 ninja linux-headers"
ARG LLVM_DOWNLOAD_URL="https://github.com/llvm/llvm-project/archive/llvmorg-11.1.0.tar.gz"
ENV LLVM_SRC_DIR=/llvm_src

## install packages and download source.
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories \
    && apk add --no-cache ${REQUIRE}

RUN wget ${LLVM_DOWNLOAD_URL} -O /tmp/llvmorg.tar.gz \
    && mkdir -p ${LLVM_SRC_DIR} \
    && tar -C ${LLVM_SRC_DIR} --strip-components 1 -zxf /tmp/llvmorg.tar.gz \
    && rm /tmp/llvmorg.tar.gz


## build clang with compiler-rt support
# but clang/clang++ binary is still linked to GNU libs.
FROM builder_env AS clang-gnu

ENV CLANG_GNU_INSTALL_PATH=/usr/local/clang-gnu/11.1.0
ENV LIBUNWIND_GNU_INSTALL_PATH=/usr/local/gun-libunwind
ENV LIBCXXABI_GNU_INSTALL_PATH=/usr/local/gun-libcxxabi
ENV LIBCXX_GNU_INSTALL_PATH=/usr/local/gun-libcxx

RUN mkdir -p /usr/local/lib /usr/local/bin /usr/local/include

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
    && ln -s ${LIBUNWIND_GNU_INSTALL_PATH}/lib/* /usr/local/lib/

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
    && ln -s ${LIBCXXABI_GNU_INSTALL_PATH}/lib/* /usr/local/lib/

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
    && ln -s ${LIBCXX_GNU_INSTALL_PATH}/lib/* /usr/local/lib/ \
    && ln -s ${LIBCXX_GNU_INSTALL_PATH}/include/* /usr/local/include/

# todo set clang install dir in ARG(no '11.1.0').
# clang will be linked to libstdc++ and libgcc (not libcxx,libcxxabi, libunwind)
RUN cd ${LLVM_SRC_DIR}/ \
    && cmake -B./llvm-build-with-compiler-rt -H./llvm -DCMAKE_BUILD_TYPE=MinSizeRel -G Ninja \
        -DCMAKE_INSTALL_PREFIX=${CLANG_GNU_INSTALL_PATH} \
        -DLLVM_ENABLE_PROJECTS="clang;compiler-rt" \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=OFF \
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
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

ARG LIBUNWIND_INSTALL_PATH=/usr/local/libunwind
ARG LIBCXXABI_INSTALL_PATH=/usr/local/libcxxabi
ARG LIBCXX_INSTALL_PATH=/usr/local/libcxx

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
    && ln -snf ${LIBUNWIND_INSTALL_PATH}/lib/* /usr/local/lib/

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
    && ln -snf ${LIBCXXABI_INSTALL_PATH}/lib/* /usr/local/lib/

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
    && ln -snf ${LIBCXX_INSTALL_PATH}/lib/* /usr/local/lib/ \
    && ln -snf ${LIBCXX_INSTALL_PATH}/include/* /usr/local/include/

# build new clang with old gnu-clang,
# the new clang/clang++ binary will not be linked to GNU libs.
# todo add option of '-DLLVM_ENABLE_FFI'
FROM clang-libs AS clang-bootstrap

ARG CLANG_INSTALL_PATH=/usr/local/clang/

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
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-linux-musl  \
    && cmake --build ./llvm-build-with-compiler-rt --target install \
    && rm -rf llvm-build-with-compiler-rt

FROM alpine:3.13.5 AS clang-toolchain

LABEL maintainer="genshen genshenchu@gmail.com" \
    description="clang/clang++ toolchain without gnu."

COPY --from=clang-bootstrap /usr/local/libunwind /usr/local/libunwind
COPY --from=clang-bootstrap /usr/local/libcxxabi /usr/local/libcxxabi
COPY --from=clang-bootstrap /usr/local/libcxx /usr/local/libcxx
COPY --from=clang-bootstrap /usr/local/clang /usr/local/clang

# make symbolic links
# musl-dev is used for C lib headers, link stdio.h
RUN mkdir -p /usr/local/lib /usr/local/bin /usr/local/include \
    && ln -s /usr/local/libunwind/lib/*  /usr/local/lib/  \
    && ln -s /usr/local/libcxxabi/lib/*  /usr/local/lib/ \
    && ln -s /usr/local/libcxx/lib/*  /usr/local/lib/ \
    && ln -s /usr/local/libcxx/include/*  /usr/local/include/ \
    && ln -s /usr/local/clang/bin/* /usr/local/bin/  \
    && apk add --no-cache libatomic linux-headers musl-dev binutils \
    && mkdir -p /project

WORKDIR /project
