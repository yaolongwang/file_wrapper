# payload 来源与许可

本目录的二进制文件来自 [MSYS2](https://www.msys2.org/) 的
`mingw-w64-ucrt-x86_64-file` 软件包，原始上游为 [file project](https://www.darwinsys.com/file/)。
所有组件均使用宽松型许可证，可自由再分发，前提是保留许可证文本。

| 文件 | 上游 | 许可证 | 许可证文件 |
|---|---|---|---|
| `file-real.exe` | file project | 2-clause BSD | [LICENSES/file-COPYING.txt](LICENSES/file-COPYING.txt) |
| `libmagic-1.dll` | file project | 2-clause BSD | [LICENSES/file-COPYING.txt](LICENSES/file-COPYING.txt) |
| `magic.mgc` | file project | 2-clause BSD | [LICENSES/file-COPYING.txt](LICENSES/file-COPYING.txt) |
| `libsystre-0.dll` | [libsystre](https://github.com/laurikari/tre) | 2-clause BSD | [LICENSES/libsystre-LICENSE.txt](LICENSES/libsystre-LICENSE.txt) |
| `libtre-5.dll` | [TRE](https://github.com/laurikari/tre) | 2-clause BSD | [LICENSES/tre-LICENSE.txt](LICENSES/tre-LICENSE.txt) |
| `magic.mgc` 数据 | file project | 2-clause BSD | 同上 |

`libsystre` 内部依赖 [TRE](https://github.com/laurikari/tre) 正则引擎
（同样为 2-clause BSD，[LICENSES/tre-LICENSE.txt](LICENSES/tre-LICENSE.txt)）。
