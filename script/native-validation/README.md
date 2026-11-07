# Native validation environments

This workflow establishes access to native build and terminal APIs before the server runtime comparison. It uses macOS ARM64, Ubuntu x86-64/ARM64 and Windows x86-64 hosted runners. Windows runs directly on Windows, without WSL.

On a pull request changing this directory or the workflow, **Native server validation environments** records OS/CPU and compiler versions, installs the Go version from `Services/relay/go.mod`, and builds and executes `pty_probe.c`. Each job has a ten-minute limit and retains its log for fourteen days. After merging, it can also be started manually with:

```sh
gh workflow run native-validation.yml --repo GordonBeeming/myterm
```

The probe creates an 80×24 terminal, resizes it to 101×31, writes input and checks a distinct response and successful child exit. Its child queries the actual terminal geometry. Unix also checks that the child has terminal stdin/stdout and a foreground process group. Windows uses `CreatePseudoConsole`, extended process attributes and a concurrent output reader kept alive through console teardown. The child wait is limited to ten seconds; the workflow timeout also bounds failures inside OS calls.

Run locally on macOS:

```sh
cc -std=c11 -Wall -Wextra -Werror script/native-validation/pty_probe.c -o /tmp/myterm-pty-probe
/tmp/myterm-pty-probe
```

On Linux, add `-lutil` to the compile command. On native Windows with Clang and the Windows SDK installed, run in PowerShell:

```powershell
clang -std=c11 -Wall -Wextra -Werror script/native-validation/pty_probe.c -o pty-probe.exe
if ($LASTEXITCODE -ne 0) { throw 'Compilation failed' }
./pty-probe.exe
if ($LASTEXITCODE -ne 0) { throw 'Probe failed' }
```

A pass establishes terminal allocation, child attachment, input/output and resized geometry on that runner. It does not establish shell fidelity, terminal emulator compatibility, server reconnects, service startup or private key storage. The Go and Rust version inventory does not prove that candidate servers build. Swift is inventoried on macOS; Linux and Windows Swift toolchains still need installation and validation if the comparison includes Swift. Windows ARM64 and Intel macOS need separate jobs if the platform support decision requires them.
