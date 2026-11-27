# ncat-ios-noad

网飞猫 iOS 去广告改包工具链（GitHub Actions 构建 + 签名验证）。

- `hook/noad.m` — 进程内 NSURLProtocol 钩子（广告配置接口返回空壳；其余 .capi 放行并打日志）
- `tests/test_hook.m` — 钩子逻辑自测（macOS 直接跑，不需要 iPhone）
- `tool.py` — unpack / patch / inject / pack / check
- `.github/workflows/build.yml` — ①逻辑自测 ②用 iOS SDK 编 dylib、注入、ad-hoc 签名、出包

本地用法（macOS）：
```bash
python3 tool.py unpack base.ipa work && python3 tool.py patch work
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -target arm64-apple-ios14.0 -isysroot "$SDK" -fobjc-arc -dynamiclib \
      -framework Foundation -install_name @executable_path/Frameworks/libnoad.dylib \
      -o libnoad.dylib hook/noad.m
python3 tool.py inject work libnoad.dylib && python3 tool.py check work && python3 tool.py pack work out.ipa
```

## 关于 CI（实测结论）

`runs-on: macos-13/14` 在**私有仓 + 免费账号**下会一直排队不动（免费额度不含 macOS 分钟）。
二选一：仓库转 public（免费 macOS runner），或账号升级 Pro（$4/月含 macOS 分钟）。
即使跑起来，Actions 也只能做「编译 dylib / 注入 / 签名 / 静态校验」——
这个 IPA 是 arm64 设备二进制，没有 IOSSIMULATOR slice，模拟器跑不了，行为只能真机验。
