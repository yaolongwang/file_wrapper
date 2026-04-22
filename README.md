# file_wrapper

把 Windows 上散落的 GNU [`file(1)`](https://www.darwinsys.com/file/) 工具
（`file.exe` + 两个 DLL + `magic.mgc`）合成一个独立的 `file.exe`。

单文件，无外部依赖，不需要 `MAGIC` 环境变量。

## 用法

和原版 `file` 一致：

```powershell
file.exe README.md
file.exe --version
```

把 `file.exe` 放到任意目录（如 `~\.local\bin`），将该目录加入 `PATH`，
之后任何终端、任何路径下都能直接 `file <文件>` 调用。

## 工作方式

外壳用 Zig 写。构建时通过 `@embedFile` 把 4 个 payload 内嵌进去，
首次运行释放到 `%LOCALAPPDATA%\file_wrapper\payload-<hash>\`，
之后转调真正的 `file.exe`，stdio 与退出码原样透传。

`<hash>` 是 payload 内容指纹，换文件重建会自动启用新目录，旧缓存自然失效。

## 构建

需要 Zig 0.16。`payload/` 已在仓库中，clone 后可直接构建：

```powershell
zig build
# 产物：zig-out\bin\file.exe（约 11 MB）
```

如需更新 payload，替换 `payload/` 下对应文件后重新构建即可，缓存目录会自动随内容指纹切换。

## 项目布局

```
file_wrapper/
├── build.zig
├── src/main.zig
├── payload/           # 内嵌的二进制 + 上游许可证
│   ├── file-real.exe
│   ├── libmagic-1.dll
│   ├── libsystre-0.dll
│   ├── libtre-5.dll
│   ├── magic.mgc
│   ├── README.md      # payload 来源说明
│   └── LICENSES/      # 上游许可证全文
├── LICENSE            # 外壳代码（MIT）
└── zig-out/bin/file.exe
```

## License

外壳代码（`build.zig`、`src/`）采用 MIT，详见 [LICENSE](LICENSE)。

`payload/` 内二进制来自 file project 与 libsystre/TRE，均为 2-clause BSD，
许可证全文保存在 [`payload/LICENSES/`](payload/LICENSES)。
