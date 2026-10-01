Third-Party Notices
===================

CallRelay original client code is licensed under the PolyForm Noncommercial
License 1.0.0 (see LICENSE). The following third-party components are used and
retain their own licenses.

1. Google WebRTC (binary framework), distributed via the stasel/WebRTC Swift
   package, release 151.0.0 (chromium milestone M151).

   - Source:   https://github.com/stasel/WebRTC
   - Artifact: WebRTC-M151.xcframework.zip
   - Verified SHA-256 / Swift Package Manager checksum:
       6f3f5693383ce65763190c46ca9f2c4325c34b83681acb9db30f01488e15f1e0
   - License:  BSD 3-Clause "New" or "Revised" License (WebRTC).
       https://webrtc.googlesource.com/src/+/refs/heads/main/LICENSE
   - WebRTC incorporates a number of third-party software components; see the
     WebRTC LICENSE and its NOTICE files for the full attribution list.

   Note on the pinned artifact: the Swift package *tag* 151.0.0 references a
   release-asset URL that currently returns HTTP 404 on GitHub. The byte
   identical M151 binary was republished under release tag 151.0.1 with the
   same name and the SAME digest above. This project therefore vendors a thin
   local package (Vendor/WebRTC/Package.swift) wrapping the M151 xcframework.
   Scripts/bootstrap.sh downloads the asset, verifies the pinned SHA-256 above
   and extracts the framework. The binary itself is not committed.

2. Apple system frameworks (SwiftUI, CallKit, PushKit, CryptoKit, AVFoundation,
   Network/URLSession and the iOS SDK) are used under the terms of the Apple
   developer programs and SDK agreements. They are operating-system components,
   not redistributed here.

All other code in this repository is original CallRelay client code. No source
from CellBridge or any other gateway project is copied into this client;
CellBridge is used only as a read-only protocol reference.
