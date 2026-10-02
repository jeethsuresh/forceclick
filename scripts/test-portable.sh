#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swiftc -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" Sources/ForceClick/{Models,Diagnostics,LLMClient,Input,Tools,UI}.swift Tests/ForceClickTests/ForceClickTests.swift -o .build/portable-tests
.build/portable-tests
