#!/usr/bin/env python3
"""网飞猫 IPA 去广告工具链（跨平台：Windows / macOS / Linux / CI 通用）

  python tool.py unpack  base.ipa   work/          # 解包
  python tool.py patch   work/                    # 等长补丁 + 改显示名 + 剥离旧签名
  python tool.py inject  work/      libnoad.dylib  # 注入 LC_LOAD_DYLIB + 放 Frameworks/
  python tool.py pack    work/      out.ipa       # 重打包
  python tool.py check   work/                    # 结构自检（不依赖 iOS 设备）

ponytail: 只做等长字符串替换，绝不改逻辑；改逻辑必须真机回归，这里不碰。
"""
import os, sys, shutil, struct, zipfile, plistlib

PATCHES = [(b"/v2/config/units.capi", b"/v2/config/uniqx.capi")]
DISPLAY_NAME = "网飞猫·喵神版"
DYLIB_NAME = "libnoad.dylib"
INSTALL_ID = "@executable_path/Frameworks/" + DYLIB_NAME
LC_LOAD_DYLIB = 0xC


def app_dir(work):
    return os.path.join(work, "Payload", os.listdir(os.path.join(work, "Payload"))[0])


def exe_path(work):
    app = app_dir(work)
    name = plistlib.load(open(os.path.join(app, "Info.plist"), "rb"))["CFBundleExecutable"]
    return os.path.join(app, name)


def cmd_unpack(base, work):
    if os.path.isdir(work):
        shutil.rmtree(work)
    zipfile.ZipFile(base).extractall(work)
    print("unpacked →", app_dir(work))


def cmd_patch(work):
    exe = exe_path(work)
    data = open(exe, "rb").read()
    n0 = len(data)
    for old, new in PATCHES:
        assert len(old) == len(new), "补丁必须等长: %r" % old
        c = data.count(old)
        assert c >= 1, "找不到目标: %r" % old
        data = data.replace(old, new)
        print("  patch %s → %s (%d 处)" % (old.decode(), new.decode(), c))
    assert len(data) == n0
    open(exe, "wb").write(data)

    p = os.path.join(app_dir(work), "Info.plist")
    d = plistlib.load(open(p, "rb"))
    d["CFBundleDisplayName"] = DISPLAY_NAME
    plistlib.dump(d, open(p, "wb"), fmt=plistlib.FMT_BINARY)
    print("  display name →", DISPLAY_NAME)

    app = app_dir(work)
    for rel in ("_CodeSignature", "embedded.mobileprovision"):
        t = os.path.join(app, rel)
        if os.path.isdir(t):
            shutil.rmtree(t); print("  rm", rel)
        elif os.path.isfile(t):
            os.remove(t); print("  rm", rel)


def cmd_inject(work, dylib):
    app = app_dir(work)
    exe = exe_path(work)
    data = open(exe, "rb").read()

    fw = os.path.join(app, "Frameworks")
    os.makedirs(fw, exist_ok=True)
    dst = os.path.join(fw, DYLIB_NAME)
    if os.path.abspath(dylib) != os.path.abspath(dst):
        shutil.copy(dylib, dst)

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    end = 32 + sizeofcmds
    off, first = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for i in range(nsects):
                soff = struct.unpack_from("<I", data, off + 72 + i * 80 + 48)[0]
                if soff and (first is None or soff < first):
                    first = soff
        off += size
    gap = first - end

    nm = INSTALL_ID.encode() + b"\0"
    cmdsize = (24 + len(nm) + 7) // 8 * 8
    assert cmdsize <= gap, "头部空隙不足: %d < %d" % (gap, cmdsize)
    if data[end:end + gap].strip(b"\0"):
        raise SystemExit("头部空隙非空（已注入过？）")

    cmd = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000) + nm
    cmd += b"\0" * (cmdsize - len(cmd))
    buf = bytearray(data)
    buf[end:end + cmdsize] = cmd
    struct.pack_into("<II", buf, 16, ncmds + 1, sizeofcmds + cmdsize)
    out = bytes(buf)
    assert len(out) == len(data)
    assert out[16384:20480] == data[16384:20480], "__text 被改动"
    open(exe, "wb").write(out)
    print("  injected %s | ncmds %d→%d | 大小不变 %d" % (INSTALL_ID, ncmds, ncmds + 1, len(out)))


def cmd_pack(work, out):
    if os.path.exists(out):
        os.remove(out)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(work):
            for f in files:
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, work))
    print("packed → %s  %.2f MB" % (out, os.path.getsize(out) / 1048576))


def cmd_check(work):
    exe = exe_path(work)
    d = open(exe, "rb").read()
    assert d[:4].hex() == "cffaedfe", "不是 arm64 thin Mach-O"
    ncmds, sizeofcmds = struct.unpack_from("<II", d, 16)
    off, libs, ok = 32, [], 0
    while ok < ncmds:
        cmd, size = struct.unpack_from("<II", d, off)
        if cmd == LC_LOAD_DYLIB:
            no = struct.unpack_from("<I", d, off + 8)[0]
            libs.append(d[off + no:off + size].split(b"\0")[0].decode())
        off += size; ok += 1
    assert ok == ncmds, "load commands 解析不完整"
    has_hook = INSTALL_ID in libs
    has_patch = d.count(PATCHES[0][1]) >= 1 and d.count(PATCHES[0][0]) == 0
    print("  arch=arm64 | ncmds=%d | dylib=%s | 静态补丁=%s | 依赖 %d" %
          (ncmds, has_hook, has_patch, len(libs)))
    print("  Frameworks/%s 存在: %s" % (DYLIB_NAME, os.path.exists(
        os.path.join(app_dir(work), "Frameworks", DYLIB_NAME))))
    assert has_hook and has_patch


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        print(__doc__); sys.exit(1)
    {"unpack": lambda: cmd_unpack(a[1], a[2]),
     "patch": lambda: cmd_patch(a[1]),
     "inject": lambda: cmd_inject(a[1], a[2]),
     "pack": lambda: cmd_pack(a[1], a[2]),
     "check": lambda: cmd_check(a[1])}.get(a[0], lambda: print(__doc__))()
