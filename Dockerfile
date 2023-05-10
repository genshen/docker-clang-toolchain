ARG ALPINE_VERSION=3.15
ARG LLVM_VERSION=14.0.6
ARG PARALLEL_LINK=4
ARG INSTALL_PREFIX=/usr/local
ARG LLVM_INSTALL_PATH=${INSTALL_PREFIX}/lib/llvm

FROM alpine:${ALPINE_VERSION} AS builder

# install prerequisites
RUN apk add --no-cache build-base cmake curl git libexecinfo-dev linux-headers ninja python3 wget zlib-dev

# download sources
ARG LLVM_VERSION
ENV LLVM_DOWNLOAD_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz"
ENV LLVM_SRC_DIR=/llvm_src
RUN mkdir -p ${LLVM_SRC_DIR} \
    && curl -L ${LLVM_DOWNLOAD_URL} | tar Jx --strip-components 1 -C ${LLVM_SRC_DIR}

# patch sources (it is also stored in patch directory)
# see discussion in: https://github.com/llvm/llvm-project/issues/51425
# NOTE patch from https://github.com/emacski/llvm-project/tree/13.0.0-debian-patches
RUN curl -L https://github.com/emacski/llvm-project/commit/2fd6a43c9adf6f05936e59a379de236b5d8885b6.diff | patch -ruN --strip=1 -d /llvm_src

# documentation: https://llvm.org/docs/BuildingADistribution.html

# build projects with gcc toolchain, runtimes with newly built projects
# NOTE for some reason LIB*_USE_COMPILER_RT is not passed to runtimes... Using CLANG_DEFAULT_RTLIB instead.
ARG PARALLEL_LINK
ARG INSTALL_PREFIX
ENV INSTALL_PREFIX=${INSTALL_PREFIX}
ARG GCC_LLVM_INSTALL_PATH=${INSTALL_PREFIX}/lib/gcc-llvm
RUN cd ${LLVM_SRC_DIR}/ \
    && cmake -B./build -H./llvm -DCMAKE_BUILD_TYPE=Release -G Ninja \
        -DBUILTINS_CMAKE_ARGS="-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF" \
        -DCLANG_DEFAULT_LINKER=lld \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCMAKE_INSTALL_PREFIX=${GCC_LLVM_INSTALL_PATH} \
        -DCOMPILER_RT_BUILD_BUILTINS=ON \
        -DCOMPILER_RT_BUILD_CRT=ON \
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_BUILD_MEMPROF=OFF \
        -DCOMPILER_RT_BUILD_ORC=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=OFF \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBUNWIND_USE_COMPILER_RT=ON \
        -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-alpine-linux-musl \
        -DLLVM_ENABLE_BINDINGS=OFF \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_ENABLE_RUNTIMES="compiler-rt;libunwind;libcxxabi;libcxx" \
        -DLLVM_ENABLE_ZLIB=YES \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
        -DLLVM_PARALLEL_LINK_JOBS=${PARALLEL_LINK} \
        -DLLVM_TARGETS_TO_BUILD="Native" \
        -DRUNTIMES_CMAKE_ARGS="-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF" \
    && cmake --build ./build --target install \
    && rm -rf build \
    && mkdir -p ${INSTALL_PREFIX}/lib ${INSTALL_PREFIX}/bin ${INSTALL_PREFIX}/include \
    && ln -s ${GCC_LLVM_INSTALL_PATH}/bin/*       ${INSTALL_PREFIX}/bin/ \
    && ln -s ${GCC_LLVM_INSTALL_PATH}/lib/*       ${INSTALL_PREFIX}/lib/ \
    && ln -s ${GCC_LLVM_INSTALL_PATH}/include/c++ ${INSTALL_PREFIX}/include/

# TODO build zlib with llvm toolchain

# build and link clang+lld with llvm toolchain
# NOTE link jobs with LTO can use more than 10GB each!
# NOTE: libexecinfo is needed for lldb and compiler-rt:fuzzer/sanitizer/profiler 
ARG LLVM_INSTALL_PATH
ARG LDFLAGS="-rtlib=compiler-rt -unwindlib=libunwind -stdlib=libc++ -L/usr/local/lib -lexecinfo -Wno-unused-command-line-argument"
RUN cd ${LLVM_SRC_DIR}/ \
    && cmake -B./build -H./llvm -DCMAKE_BUILD_TYPE=MinSizeRel -G Ninja \
        -DBUILTINS_CMAKE_ARGS="-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF;-DCMAKE_SHARED_LINKER_FLAGS='${LDFLAGS}';-DCMAKE_MODULE_LINKER_FLAGS='${LDFLAGS}';-DCMAKE_EXE_LINKER_FLAGS='${LDFLAGS}'" \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_LINKER=lld \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_INSTALL_PREFIX=${LLVM_INSTALL_PATH} \
        -DCMAKE_MODULE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
        -DCOMPILER_RT_BUILD_BUILTINS=ON \
        -DCOMPILER_RT_BUILD_CRT=ON \
        -DCOMPILER_RT_BUILD_MEMPROF=OFF \
        -DCOMPILER_RT_BUILD_ORC=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
        -DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBUNWIND_USE_COMPILER_RT=ON \
        -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-alpine-linux-musl  \
        -DLLVM_DISTRIBUTION_COMPONENTS="clang;LTO;clang-format;clang-resource-headers;lld;builtins;runtimes" \
        -DLLVM_ENABLE_BINDINGS=OFF \
        -DLLVM_ENABLE_EH=ON \
        -DLLVM_ENABLE_LIBCXX=ON \
        -DLLVM_ENABLE_LTO=ON \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_ENABLE_RTTI=ON \
        -DLLVM_ENABLE_RUNTIMES="compiler-rt;libunwind;libcxxabi;libcxx" \
        -DLLVM_ENABLE_ZLIB=ON \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
        -DLLVM_PARALLEL_LINK_JOBS=${PARALLEL_LINK} \
        -DLLVM_TARGETS_TO_BUILD="X86" \
        -DLLVM_USE_LINKER=lld \
        -DRUNTIMES_CMAKE_ARGS="-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF;-DCMAKE_SHARED_LINKER_FLAGS='${LDFLAGS}';-DCMAKE_MODULE_LINKER_FLAGS='${LDFLAGS}';-DCMAKE_EXE_LINKER_FLAGS='${LDFLAGS}'" \
    && cmake --build ./build --target install-distribution \
    && rm -rf build


FROM alpine:${ALPINE_VERSION} AS clang-toolchain

ARG INSTALL_PREFIX
ARG LLVM_INSTALL_PATH

# assemble final image
COPY --from=builder ${LLVM_INSTALL_PATH} ${LLVM_INSTALL_PATH}
RUN mkdir -p ${INSTALL_PREFIX}/lib ${INSTALL_PREFIX}/bin ${INSTALL_PREFIX}/include \
    && ln -s ${LLVM_INSTALL_PATH}/bin/*       ${INSTALL_PREFIX}/bin/ \
    && ln -s ${LLVM_INSTALL_PATH}/lib/*       ${INSTALL_PREFIX}/lib/ \
    && ln -s ${LLVM_INSTALL_PATH}/include/c++ ${INSTALL_PREFIX}/include/
RUN apk add --no-cache binutils libexecinfo linux-headers musl-dev zlib

# set llvm toolchain as default
ENV CC=clang
RUN ln -s ${INSTALL_PREFIX}/bin/clang ${INSTALL_PREFIX}/bin/cc
ENV CXX=clang++
RUN ln -s ${INSTALL_PREFIX}/bin/clang++ ${INSTALL_PREFIX}/bin/c++
RUN ln -s ${INSTALL_PREFIX}/bin/lld ${INSTALL_PREFIX}/bin/ld
ENV CFLAGS=""
ENV CXXFLAGS="-stdlib=libc++"
ENV LDFLAGS="-rtlib=compiler-rt -unwindlib=libunwind -stdlib=libc++ -lc++ -lc++abi"

# add user mount point
RUN mkdir -p /project
WORKDIR /project
