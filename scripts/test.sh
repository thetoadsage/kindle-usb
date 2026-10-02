#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
xcrun swiftc ${SDKROOT:+-sdk "$SDKROOT"} Sources/KindleUSB/Types.swift Sources/KindleUSB/UploadPlan.swift Sources/KindleUSB/TransferSupport.swift Tests/main.swift -o .build/tests/file-rules
.build/tests/file-rules
