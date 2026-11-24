# Android 开发环境

> Android SDK 和开发环境的安装配置脚本

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `install_android_sdk.sh` | Android SDK 安装脚本 | ❌ | ❌ |
| `optimize-android-phone.sh` | 手机提速 / 存储整理（adb 实机维护，不需要 root） | ✅ | ✅ |

## 🚀 快速开始

### 安装 Android SDK

```bash
cd android
./install_android_sdk.sh
```

## 🔧 详细说明

### install_android_sdk.sh - Android SDK 安装脚本

**功能**: 安装 Android SDK 开发环境

**SDK 组件**:
- Android SDK Platform
- Android SDK Build-Tools
- Android SDK Platform-Tools
- Android SDK Tools
- 模拟器镜像

**环境变量配置**:
```bash
export ANDROID_HOME=/path/to/android-sdk
export PATH=$PATH:$ANDROID_HOME/tools
export PATH=$PATH:$ANDROID_HOME/platform-tools
```

**常用命令**:
```bash
# 查看 SDK 版本
sdkmanager --list

# 安装平台
sdkmanager "platforms;android-30"

# 安装构建工具
sdkmanager "build-tools;30.0.3"
```

## 🛠 实机维护：手机提速与存储整理

`optimize-android-phone.sh` 只走 adb shell 权限（不需要 root），不绑品牌机型，Android 8~10 都能用。
默认动作是**只读报告**，任何改动都要显式给动作参数。

```bash
cd android
./optimize-android-phone.sh                      # 体检报告，什么都不改
./optimize-android-phone.sh --dry-run --auto     # 先看安全档会做什么，不写设备
./optimize-android-phone.sh --auto --yes         # 安全档：搬白名单媒体 + 删可再生缓存 + 提速
./optimize-android-phone.sh --move-media         # 只搬媒体到外置卡
./optimize-android-phone.sh --include-sounds     # 连同通话录音一起搬（见下方警告）
./optimize-android-phone.sh --purge-cache        # 只删可再生缓存
./optimize-android-phone.sh --trim-cached        # 杀缓存进程，当场回收内存
./optimize-android-phone.sh --bg-limit 12        # 压低后台进程上限（show / reset）
./optimize-android-phone.sh --scan-off           # 关掉「始终扫描 WLAN/蓝牙」（--scan-on 恢复）
./optimize-android-phone.sh --compile            # 未冻结的第三方应用做全量 AOT
./optimize-android-phone.sh --freeze com.x.y     # 冻结（--unfreeze 解冻）
./optimize-android-phone.sh --uninstall-frozen   # 显式才会卸载已冻结应用
./optimize-android-phone.sh --rollback           # 按 ledger 复原设置、把媒体搬回机身
```

搬移动作的顺序是**复制 → 文件数与总字节校验 → 源目录改名暂存 → 重建媒体索引 → 删暂存**，
任何一步失败都保留机身那份；`--rollback` 能原路搬回来。
写过的系统设置原值记在 `~/.android-tune/<序列号>.ledger.tsv`（制表符纯文本，人能直接 grep），
同一把钥匙只记第一次的旧值，避免把上一轮改过的值当原值存下来。
`PURGED` 项不可回滚——删的本来就是可再生缓存。

白名单只有 `huawei/Themes`、`Photo`、`backup`、`Music`、`Movies` 这几个纯媒体目录，
黑名单写死在脚本里：`Android/data`、`Android/obb`、`tencent/MicroMsg`、`alipay`、`autonavi`、
`amap`、`Download`、`DCIM` 一律拒绝——这些是应用按绝对路径自己记账的，搬走只会换来
「图片已过期 / 要重新登录 / 离线地图重新下载」。通话录音默认不搬：实测 788 个录音文件里
只有 37 条进了媒体库，华为拨号是按路径查的，搬走文件不丢但录音列表可能打不开。

几条实测结论，省得下次重新试一遍：

- **EMUI 9 的 `pm` 没有 `move-storage`**（`Unknown command: move-storage`），
  「把应用装到 SD 卡」这条路根本不存在，脚本只能整理数据。
- **高德离线地图放卡上只能靠应用内切换**：「离线地图 → 更改存储位置 → 外置卡」，
  目标路径是 `/storage/<卡UUID>/Android/data/com.autonavi.minimap/files`。这个切换会**真的搬数据**，
  中途失败（实测报「存储路径被占用」）会把已下载的离线包清掉，只能重新下载；
  切换时别拔卡、别让系统去杀高德，也不要用 adb 去点它的按钮——那一行是整行可点的，
  点偏就直接触发搬迁。所以脚本对 `autonavi` 目录一律列入黑名单，不代劳。
- **写 `activity_manager_constants` 的 `max_cached_processes` 收效有限**：值确实写进去了
  （32 → 12），但 `CUR_MAX_CACHED_PROCESSES` 仍是 36——EMUI 用 `mOverrideMaxCachedProcesses`
  覆盖掉了。脚本会实测前后差值，没变就明确警告，不假装成功。
- **真正当场有效的是 `am kill-all`**：实测 MemAvailable 1.45G → 1.86G、SwapFree +400M、
  缓存进程 16 → 1。缓存进程本来就是随时可重启的，不丢登录态；用一会儿会重新长回来，隔一两天跑一次。
- **清理类工具在这类机器上没意义**：`dumpsys diskstats` 报的 App Cache Size 只有 4.5M，
  `pm trim-caches` 榨不出东西；真正的大头是 APK（本机 13.4G）、高德离线地图
  （`Android/data/com.autonavi.minimap` 7.16G）和微信数据（1.7G）。
- **`du -k 目录` 再求和会重复累加父目录和子目录**，实测把 `Android/` 算成 76G 而 /data 总共才 54G；
  脚本一律用 `du -sk`。
- **媒体库扫描是异步的**：搬到外置卡后不广播就查不到（实测 0 条），
  逐文件 `MEDIA_SCANNER_SCAN_FILE` 才有；广播完立刻查会少几十条，等两秒再判。
  删掉源路径后要按 `_data` 前缀清死条目，URI 必须是**单数** `content://media/external/file`，
  写成 `external/files` 会静默失败，留一堆灰掉打不开的缩略图。
- **`pgrep -f dex2oat` 会匹配到自己**（`sh -c pgrep -f dex2oat` 那条壳），
  脚本改用 `ps -A -o NAME | grep -c dex2oat`。后台编译正在跑的时候别测反应速度。

## 🔗 相关链接

- [Android 开发者网站](https://developer.android.com/)
- [Android Studio 下载](https://developer.android.com/studio)

## 📝 使用场景

- **Android 应用开发**: 原生 Android 应用开发
- **混合应用开发**: React Native、Flutter 等跨平台开发
- **自动化测试**: Android UI 自动化测试
- **设备调试**: Android 设备调试和测试