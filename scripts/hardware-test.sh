#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "--allow-test-writes" ]]; then
    echo 'Close the GUI and other MTP clients first. This creates, transfers, renames, and deletes only disposable test items on the Kindle.'
    echo 'Run with --allow-test-writes to proceed.'
    exit 1
fi
prefix="$PWD/.build/dependencies"
mkdir -p .build/tests/CMTP
printf 'module CMTP { header "%s/Sources/CMTP/include/CMTP.h" export * }\n' "$PWD" > .build/tests/CMTP/module.modulemap
clang -I"$prefix/include" -ISources/CMTP/include -c Sources/CMTP/CMTP.c -o .build/tests/CMTP.o
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
xcrun swiftc ${SDKROOT:+-sdk "$SDKROOT"} -I .build/tests/CMTP -Xcc -I"$prefix/include" -L"$prefix/lib" -lmtp Sources/KindleUSB/Types.swift Sources/KindleUSB/UploadPlan.swift Sources/KindleUSB/TransferSupport.swift Sources/KindleUSB/MTPClient.swift Tests/Hardware/main.swift .build/tests/CMTP.o -o .build/tests/hardware
.build/tests/hardware
