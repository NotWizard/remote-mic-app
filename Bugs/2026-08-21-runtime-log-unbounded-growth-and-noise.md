# 运行日志无界增长，单条消息占体积 47%，且全局可读

- 编号：A3
- 时间：2026-08-21
- 状态：已修复，自动化通过；真机长驻未验收
- 影响范围：所有安装，日志文件 `~/Library/Logs/RemoteMic/runtime.log`
- 功能点：`AppLogger` 写入路径、虚拟音频释放路径

## 现场实测数据

用户机器上的日志在 11 天内涨到 **21 MB / 113242 行**，无人清理。去重后仅 **220 类**消息，前 12 类占 **86.8%**：

| 消息 | 行数 | 字节 | 占比 |
| --- | --- | --- | --- |
| `AUDIO RELEASE completed` | 30750 | 9.3 MB | **47.1%** |
| `BLE CONNECTING` | 21674 | 1.9 MB | 9.8% |
| `BLE CONNECT TIMEOUT` | 21329 | 0.8 MB | 4.2% |

文件权限为 `-rw-r--r--`，同机任意进程可读，内容含用户配置的目标 App bundle ID 与音频设备名。

原始日志已备份至 `~/Desktop/remote-mic-audit-evidence/`，作为 A4、A5、A6 的证据来源。

## 根因

四个相互叠加的原因：

1. **`AppLogger.write(_ message: String)` 不是 `@autoclosure`**，所以调用点里 `state={\(audioOutput.diagnosticState())}` 这类昂贵参数被无条件求值。`diagnosticState()` 每次约 9 次 CoreAudio 同步 IPC。
2. **`releaseVirtualAudioOutputIfUnused` 缺"无事可释放"的幂等门**：仅在 `shouldKeepVirtualAudioActive` 上有守卫。引擎已为 nil、用户未选设备时照样跑完整流程并输出 316 字节的诊断行。蓝牙每轮重连的两次状态跃迁各触发一次空转释放，这就是 47% 的来源。
3. **每写一行都 `fileExists` → `FileHandle(forWritingTo:)` → `seekToEnd` → `write` → `close`**，113242 行即同样次数的开关文件；`catch { return }` 静默丢弃写入失败。
4. **无轮转、无大小上限**，文件按 1.92 MB/天无限增长。

## 修复

- `write` 改为 `@autoclosure`，一处改动让全代码库 188 个调用点的昂贵参数变惰性求值。消息仍在调用线程构建——在日志队列上求值会把未同步的 CoreAudio 与 AVAudioEngine 访问移出主线程。
- 新增纯函数 `VirtualAudioReleaseGate`，在五项条件全满足时跳过释放：引擎无设备、0 待播缓冲、`isAudioOutputReady` 为假、`testToneStatus` 已是释放态、默认输入回退不会执行。第五项用惰性闭包，只在前四项便宜判定通过后才做 1 次 CoreAudio 读。
- 常驻 append 句柄；4 MiB × (1 当前 + 3 归档) = 16 MiB 上限；文件按 **0600** 创建，并对已存在的文件收紧权限；写入失败计数并单次报到 stderr，不经过 `self` 以避免递归日志。

### 折叠：首版被复核否决

首版折叠键取"到第一个 `=` token 为止"。复核者按实现规则重放真实日志，实测抑制 78165 行，其中 **1586 行内容与被保留行不同**，差异恰好落在第一个 `=` 之后：`AUDIO REBIND begin reason=recovery_*` 里真正有区分度的是 `bound_to_selected=false`；`VOICE FN MAPPING applied=true` 里是 `neutralized=`/`power_suppressed=`；还有 `APP FOCUS failed bundle=`、`AUDIO CONFIGURE begin target=` 等共 7 类。

**这正是本仓库 A6 缺陷的定义**（多种原因压成同一条，线上无法定位），首版等于把它从一处推广到 220 类消息。

已改为**显式白名单 opt-in**：仅 `BLE CONNECTING`、`BLE CONNECT TIMEOUT`、`BLE SCANNING` 三类参与折叠。依据是这三类为蓝牙重连轮询，占 43557/113242 行（38.5%），且每类渲染文本逐字节相同（分别有 1、1、5 种不同文本）。折叠键返回整条消息本身，因此同键必然同字节；超长消息拒绝折叠以防截断碰撞。实测 0 行内容被错误合并。

其余高频类型每行都带 `state={…}`/`target={…}` 转储，全部超过 160 字符、永不参与折叠。幂等门已独立拿下 47%，折叠的边际收益不值得承担 A6 那类风险。

### 投影计算：首版前提被证伪

首版声称"日志里零条 `AUDIO DEFAULT_INPUT` 事件，故 30880/30880 释放行全是 no-op"。实测**有 1 条**：

```text
2026-08-21T10:02:55Z AUDIO DEFAULT_INPUT fallback_applied reason=bluetooth_not_ready target={name=MacBook Pro麦克风 id=83}
```

紧接其后是两条 `AUDIO RELEASE completed reason=bluetooth_not_ready`，说明默认输入回退在被门控的同一路径上真实执行过。首版脚本把五项条件中的第 4、5 项硬编码成乐观常量，只重放 3/5，依据正是这个假前提。

脚本已重写为从日志字段推导全部五项条件。修正结果：**30879/30880 被门控，而非 30880/30880**。第五项恰好被违反一次，两种独立建模方法均得 1。门在该次真实回退时正确地拒绝跳过。

## 验证

- `swift test`：277 项通过（A3 相关新增 15 项，均为真实行为测试）
- `./scripts/test.sh`：42 项通过
- `./scripts/build-driver-dmg.sh`：通过，确认打包链未被打断
- 负向对照：删掉幂等门 → 对应测试变红；反转轮转、改回 0644、去掉 `@autoclosure`、关闭折叠 → 分别红 1/2/1/5 项；把白名单改回全局启发式 → 4 个测试红、18 个 issue（受害测试把 42 行折成 7 行并丢失 7 条不同消息）

### 修复前后对比（按真实日志重放）

| | 行数 | 体积 | 日均 |
| --- | --- | --- | --- |
| 修复前 | 113242 | 21.49 MB | 1.92 MB |
| 修复后 | 53823 | 10.59 MB | 0.95 MB |
| 削减 | **−52.5%** | **−50.7%** | −50.5% |

其中幂等门贡献 −30879 行 / −9.32 MB，白名单折叠贡献 −35608 行 / −2.29 MB（含汇总行开销）。

## 自动化与真机边界

自动化覆盖惰性求值、轮转与保留份数、文件权限、折叠计数、幂等门。**未验证**：真机 11 天长驻的实际增长曲线、轮转在真实使用节奏下的触发频率、以及投影中"引擎消失后待播缓冲恒为 0"这一假设。

已知未处理项：`BridgeAppModel` 有 78 处硬编码 `AppLogger.shared`，无注入点，因此单元测试会写入真实日志文件。实测每次 `swift test` 仅增约 3.4 KB，相对 4 MiB 阈值需约 1200 次才触发轮转，经复核确认不必在本项内解决；但这已导致原始 11 天证据被轮转一次，故已另存备份。

隐私方面：日志仍记录目标 App 的 bundle ID 与音频设备名，与 README「不记录外设标识」的表述存在差距。本项只把文件权限收紧到 0600，**是否删除这些字段或改写 README 属于产品决策，尚未处理**。
