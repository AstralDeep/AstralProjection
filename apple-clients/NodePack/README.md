# Node pack

The node pack is Deep's Python node as one relocatable directory for macOS on Apple silicon. The Mac app downloads it on request and runs it as a supervised background process on Plane's SQLite backend. The app does not bundle it.

## Build it

Run these from this directory. Rust must come from rustup with the Apple targets.

```text
KERNEL_REPO=<path or URL of AstralKernel> ./build_kernel.sh
python3 assemble_pack.py
```

`build_kernel.sh` clones the pinned kernel commit into a private cache, builds the `astral_kernel` wheel with uniffi and the `astral-mailbox` binary, and writes them to `build/kernel`. It never touches another kernel checkout.

`assemble_pack.py` reads `pins.json`. It writes `build/pack` with three files:

- `node-pack.json` is the descriptor the app fetches. It holds the archive name, size and SHA-256, the installed size and the manifest SHA-256.
- `node-pack-manifest.json` is a copy of the manifest inside the archive. It lists every input and the SHA-256 of every file.
- `astral-node-pack-<version>-macos-arm64.tar.gz` is the pack.

Set `NODEPACK_REPO_<NAME>` to a local path for any source repository that is not reachable on GitHub, for example `NODEPACK_REPO_ASTRALDEEP`. `NODEPACK_WORK` moves the cache.

For local integration, use `./build_kernel.sh --source /path/to/AstralKernel` and
`NODEPACK_SOURCE_ASTRALDEEP=/path/to/AstralDeep python3 assemble_pack.py`. Component checkouts use the
same `NODEPACK_SOURCE_<NAME>` convention. The older `NODEPACK_REPO_<NAME>` local-path spelling remains
accepted. Every local source must be a clean checkout at the exact full SHA in `pins.json` or Deep's
composition, including its untracked files and submodules. The builder exports committed trees and
checks the source again afterward; it does not publish a local kernel or copy working files into the
pack. `NODEPACK_KERNEL_SOURCE` is the environment equivalent of the kernel's `--source` option.

## What is pinned

- CPython 3.11 from python-build-standalone, by release, URL and SHA-256. The script fetches it only from that project's GitHub releases.
- Deep at one commit. The Plane, LETS, ROTE, Projection and Primitives revisions come from Deep's `config/astral-composition.json` at that commit.
- The kernel wheel and mailbox, built from the kernel commit in `pins.json`.
- Every third-party wheel, by SHA-256, in `node-requirements.lock`. Build tools are hashed in `build-requirements.lock`.

`pins.json` also records what the pack leaves out and why. The manifest repeats it.

## Host it

A release host is the owner's choice. Any static file host works. Serve `node-pack.json` and the archive from the same directory over https. For a trial on one Mac, serve the directory on loopback:

```text
cd build/pack && python3 -m http.server 18650 --bind 127.0.0.1
```

Then enter `http://127.0.0.1:18650/node-pack.json` as the node pack address in Settings. Plain http is accepted only for loopback. A build can pin the descriptor digest with the `ASTRALNodePackSHA256` Info.plist key and preset the address with `ASTRALNodePackURL`.

## Run it

The control is in Settings for the mesh, under "Node on this Mac". It appears only in the direct-download build, because the Store build is sandboxed and cannot run downloaded programs.

The app shows the download and installed sizes, downloads the archive, checks its size and SHA-256, unpacks it into staging, checks the manifest digest and every file, and only then moves it into Application Support. A failed or tampered download leaves the previous pack in place.

The node runs with the personal profile and its own private home. The app restarts it after a crash with growing delays. It stops the node on quit unless Keep running is on. Logs go to `logs/node.log` in the node home, rotate at 2 MiB with four backups and have secret values removed.

## Tests

```text
python3 -m pytest tests
swift test --package-path ../AstralCore --filter "NodePack|NodeSupervisor|NodeHost"
ASTRAL_NODE_PACK_URL=http://127.0.0.1:18650/node-pack.json swift test --package-path ../AstralCore --filter NodePackRealRun
```

The last command downloads, installs, starts and stops the real pack. It is skipped when the variable is unset.
