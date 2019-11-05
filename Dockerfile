FROM alpine:latest AS builder_env

ARG REQUIRE="build-base wget cmake python3 ninja linux-headers"
ARG LLVM_DOWNLOAD_URL="https://github.com/llvm/llvm-project/archive/llvmorg-9.0.0.tar.gz"
ENV LLVM_SRC_DIR=/llvm_src

## install packages and download source.
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories \
    && apk add --no-cache ${REQUIRE}

RUN wget ${LLVM_DOWNLOAD_URL} -O /tmp/llvmorg.tar.gz \
    && mkdir -p ${LLVM_SRC_DIR} \
    && tar -C ${LLVM_SRC_DIR} --strip-components 1 -zxf /tmp/llvmorg.tar.gz \
    && rm /tmp/llvmorg.tar.gz

FROM builder_env AS cxx_runtime

ARG LIBUNWIND_INSTALL_PATH=/usr/local/libunwind
ARG LIBCXXABI_INSTALL_PATH=/usr/local/libcxxabi
ARG LIBCXX_INSTALL_PATH=/usr/local/libcxx

RUN mkdir -p /usr/local/lib /usr/local/bin /usr/local/include

# build libunwind
RUN cd ${LLVM_SRC_DIR}/libunwind \
    && cmake -B./build -H./ \
        -DCMAKE_INSTALL_PREFIX=${LIBUNWIND_INSTALL_PATH} \
        -DLIBUNWIND_ENABLE_SHARED=OFF \
        -DLLVM_PATH=../llvm \
        -DCMAKE_C_FLAGS="-fPIC" \
        -DCMAKE_CXX_FLAGS="-fPIC" \
    && cmake --build ./build --target install \
    && rm build -rf \
    && cd ../  \
    && ln -s ${LIBUNWIND_INSTALL_PATH}/lib/* /usr/local/lib/

## build libc++abi
RUN cd ${LLVM_SRC_DIR}/libcxxabi \
    && cmake -B./build -H./ \
        -DCMAKE_INSTALL_PREFIX=${LIBCXXABI_INSTALL_PATH} \
        -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXXABI_LIBUNWIND_PATH=../libunwind \
        -DLIBCXXABI_LIBCXX_INCLUDES=../libcxx/include \
        -DLLVM_PATH=../llvm \
    && cmake --build ./build --target install \
    && rm build -rf \
    && cd ../   \
    && ln -s ${LIBCXXABI_INSTALL_PATH}/lib/* /usr/local/lib/

## build libcxx
RUN cd ${LLVM_SRC_DIR}/libcxx \
    && cmake -B./build -H./ -G Ninja \
        -DCMAKE_INSTALL_PREFIX=${LIBCXX_INSTALL_PATH} \
        -DLIBCXX_ENABLE_SHARED=ON -DLIBCXX_ENABLE_STATIC=ON  \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_HAS_GCC_S_LIB=OFF \
        -DCMAKE_SHARED_LINKER_FLAGS="-lunwind" \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXX_CXX_ABI_INCLUDE_PATHS=../libcxxabi/include \
        -DLLVM_PATH=../llvm \
    && cmake --build ./build --target install \
    && rm build -rf \
    && cd ../ \
    && ln -s ${LIBCXX_INSTALL_PATH}/lib/* /usr/local/lib/ \
    && ln -s ${LIBCXX_INSTALL_PATH}/include/* /usr/local/include/

## build clang with compiler-rt, libcxx and libunwind support, 
# but clang/clang++ binary is still linked to GNU libs.
FROM cxx_runtime AS compiler-rt

ARG CLANG_GNU_INSTALL_PATH=/usr/local/clang-gnu/9.0.0
ARG CLANG_INSTALL_PATH=/usr/local/clang/

# todo set clang install dir in ARG(no '9.0.0').
RUN cd ${LLVM_SRC_DIR}/ \
    && cmake -B./llvm-build-with-compiler-rt -H./llvm -DCMAKE_BUILD_TYPE=MinSizeRel -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr/local/clang-gnu/9.0.0 \
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


# build new clang with old clang,
# the new clang/clang++ binary will not be linked to GNU libs.
RUN cd ${LLVM_SRC_DIR}/ \
    && export CC=${CLANG_GNU_INSTALL_PATH}/bin/clang  \
    && export CXX=${CLANG_GNU_INSTALL_PATH}/bin/clang++  \
    && cmake -B./llvm-build-with-compiler-rt -H./llvm -DCMAKE_BUILD_TYPE=MinSizeRel -G Ninja \
        -DCMAKE_INSTALL_PREFIX=${CLANG_INSTALL_PATH} \
        -DLLVM_ENABLE_PROJECTS="clang;compiler-rt" \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=OFF \
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-linux-musl  \
    && cmake --build ./llvm-build-with-compiler-rt --target install \
    && rm -rf llvm-build-with-compiler-rt

FROM alpine:latest AS clang-toolchain

LABEL maintainer="genshen genshenchu@gmail.com" \
    description="clang/clang++ toolchain without gnu."

ARG USER=user
ENV WORKDIR="/project"

COPY --from=cxx_runtime /usr/local/libunwind /usr/local/libunwind
COPY --from=cxx_runtime /usr/local/libcxxabi /usr/local/libcxxabi
COPY --from=cxx_runtime /usr/local/libcxx /usr/local/libcxx
COPY --from=compiler-rt /usr/local/clang /usr/local/clang

# make symbolic links
# musl-dev is used for C lib headers, link stdio.h
RUN mkdir mkdir -p /usr/local/lib /usr/local/bin /usr/local/include \
    && ln -s /usr/local/libunwind/lib/*  /usr/local/lib/  \
    && ln -s /usr/local/libcxxabi/lib/*  /usr/local/lib/ \
    && ln -s /usr/local/libcxx/lib/*  /usr/local/lib/ \
    && ln -s /usr/local/libcxx/include/*  /usr/local/include/ \
    && ln -s /usr/local/clang/bin/clang /usr/local/bin/clang  \
    && ln -s /usr/local/clang/bin/clang++ /usr/local/bin/clang++ \
    && apk add --no-cache musl-dev binutils sudo \
    && adduser -D ${USER} \
    && echo "${USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && mkdir -p ${WORKDIR} \
    && chown -R ${USER}:${USER} ${WORKDIR}

WORKDIR ${WORKDIR}
USER ${USER}
