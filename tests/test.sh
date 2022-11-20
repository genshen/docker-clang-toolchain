#!/bin/sh

# normal case
clang++ main.cpp -o main1

# static link
clang++ main.cpp -static -lc++ -lc++abi -o main2

# test sanitizers
clang++ main.cpp -fsanitize=undefined -o main3

# test fuzzer (code from: https://i-m.dev/posts/20190831-143715.html)
clang -fsanitize=fuzzer -o with_fuzzer test-fuzzer.c
