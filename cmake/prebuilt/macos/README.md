# Bundled macOS dependencies

These dependency archives are copied from the `macos` branch of
[`deathkiller/jazz2-libraries`](https://github.com/deathkiller/jazz2-libraries/tree/macos)
at commit `85f04925036175b8b769488ac6dfe903786adbb2`.

| Archive | SHA-256 |
| --- | --- |
| `jazz2-libraries-macos-arm64.tar.gz` | `96e7ea124b60ef4bb34b2d8039011a62319958fb24a8827bd9d54698594ff3e9` |
| `jazz2-libraries-macos.tar.gz` | `96e17f03b10c07a6c2194a478fe54ca3a9c87d4060fb03108c6e042af4547031` |

CMake selects the matching archive for the target architecture and extracts it
into that build's dependency directory. The x64 archive is unchanged from the
upstream commit above. In the ARM64 archive, the Ogg and Vorbis runtime
framework binaries were rebuilt for arm64 from the upstream Xiph sources:

- libogg 1.3.5, source commit `e1774cd77f471443541596e09078e78fdc342e4f`
- libvorbis 1.3.7, source commit `0657aee69dec8508a0011f47f3b69d7538e9d262`

The rebuilt binaries retain the existing framework layout and install names.
The ARM64 archive carries the Xiph `COPYING` notices in the framework
resources; the x86_64 archive does not. Copies of both notices are kept under
`cmake/licenses` and the macOS build script places them in
`Contents/Resources/Licenses` after flattening the frameworks. Keep the
upstream notices and licenses for all bundled dependencies with any
redistributed build.
