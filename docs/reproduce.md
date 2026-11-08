# 复现

三步，加六个坑。**先读 §0，否则你可能复现出一个"一切正常但频谱全零"的结果。**

---

## 0 先看这里：最容易踩的是"静默失败"

本仓库的 RTL 里**没有任何绝对路径**：5 个 `$readmemh` 用的是相对文件名（`iq4.mem` 等），
由两个脚本负责把 `.mem` 送到解析器能找到的位置：

| 场景 | 谁负责搬 | 目标目录 |
|---|---|---|
| 综合 | `scripts/_pre_copy_mem.tcl`（被 `build_project.tcl` 挂成 `STEPS.SYNTH_DESIGN.TCL.PRE`） | 综合 run 目录 |
| 行为仿真 | `scripts/run_sim_wave.tcl` | xsim run 目录 |

这条链断掉的后果是**静默**的：综合照常完成、比特流照常生成、板子照常启动、串口照常出报文，
只是激励全零、谱也全零。所以复现的判据不是"跑完了"，而是**日志里 `8-4445` 一个都没有**（坑 ①）。

---

## 1 环境

| 项 | 要求 |
|---|---|
| Vivado | **2020.2**（跨版本未验证，换版本必须重跑实现策略扫描） |
| 器件 | `xc7a35tfgg484-2`（Artix-7，**只有 90 个 DSP48E1**） |
| 板卡 | 正点原子达芬奇 XC7A35T-FGG484（引脚约束只对这一块有效） |
| Python | 3.x + numpy（只跑定点模型与对拍时需要） |
| 路径 | **纯英文、无空格**（Vivado 2020.2 对中文路径不友好） |

---

## 2 三步

### 第一步 · 建工程

```bash
vivado -mode batch -source scripts/build_project.tcl
```

工程建在 `_proj/fft_spectrum_1gsps.xpr`（`_proj/` 已进 `.gitignore`），**不进仓库根目录**，`git status` 保持干净。
脚本做的事：按依赖顺序加入 35 个设计源（10 自有 + 15 第三方 + 10 生成件）、1 个约束、MMCM 的 `.xci`，设顶层 `board_top_4lane`，
设工程级 define `CLK2_FREQ_MHZ=125`，并把 `sim/*.mem` 通过 `STEPS.SYNTH_DESIGN.TCL.PRE`
钩子（`scripts/_pre_copy_mem.tcl`）拷进综合 run 目录——这样 **RTL 里的 `$readmemh` 用相对名字也能找到**。

预期末行：`### BUILD_PROJ_DONE`

### 第二步 · 综合并核对

GUI 里就是打开 `_proj/fft_spectrum_1gsps.xpr` → Run Synthesis。批处理用：

```bash
vivado -mode batch -source scripts/run_synth.tcl
```

脚本会 `launch_runs synth_1`、等它跑完，然后直接把下面四项打出来，不用你去翻 300 KB 的日志：

| 输出行 | 期望 | 不符说明什么 |
|---|---|---|
| `### SYNTH_84445_COUNT` | **0** | >0 就是 ROM 文件没找到 → ROM 全 0 → 频谱全 0（坑 ①） |
| `### SYNTH_DSP` | **85** | 差一个数就说明源文件没对上 |
| `### SYNTH_RAMB36` / `### SYNTH_RAMB18` | **27 / 28** | 折合 41 个 RAMB36 等效块（41/50 = 82%） |
| `### SYNTH_STATUS` | `synth_design Complete!` | 否则看 `_proj/fft_spectrum_1gsps.runs/synth_1/runme.log` |

> 综合后的 LUT / FF 数与实现后不同（12819 / 21320 是**布局布线后**的数），所以脚本故意不打这两项。
> 要核 LUT / FF 就看 `docs/reports/report_v11_util_route.rpt:34` 与 `:39`。
> 同理，"BRAM 41/50" 是 **RAMB36 等效口径**（27 个 RAMB36 + 28 个 RAMB18 = 27 + 14 = 41），
> 原始 BRAM cell 数是 55——这两个数都对，别把它们当成矛盾。

**已实测（2026-11-09）**：把仓库整树拷到纯英文路径（`E:\_oss_test\` 同级的干净目录），
依次跑 `build_project.tcl` 与 `run_synth.tcl`，得到

```
### SYNTH_STATUS      synth_design Complete!
### SYNTH_84445_COUNT 0
### SYNTH_DSP         85
### SYNTH_RAMB36      27
### SYNTH_RAMB18      28
```

也就是说这条三步路径不是"应该能跑"，是**跑过**。若你跑出不同的 DSP 数，先查是不是改过源文件。

`scripts/open_check.tcl` 是只清点不综合的轻量版（源码/IP/约束是否齐、编译顺序对不对），
改完源文件想快速自检时用它。

### 第三步 · 跑仿真看波形

在 Vivado Tcl Console 里：

```tcl
source {<repo>/scripts/run_sim_wave.tcl}
```

这个脚本不能拆成"先点 Run Simulation 再拖信号"——xsim 只记录**开跑那一刻已在波形窗里的信号**，
后拖进去的内部信号永远是空的。脚本的顺序是：elaborate（runtime 0）→ launch → 换 `wave_demo.wcfg`
（14 个信号）→ 恢复 runtime=all → run all。

预期末态：

```
TB_END ndone=8 nwv=20714 nwr=12292 nfend=11 assert_fail=0
LAT cyc=2128 ns=17024
```

波形看点：光标 52.6 µs 处看 `fend` / `ds_start` 的相位关系；52.6–63.7 µs 看 `ds_busy` / `pb_busy`
的重叠——那一段就是"pass B(k) 与 pass A(k+1) 并行"，也是 N=1 成立的直接证据。

### 可选 · 逐 bin 对拍

```bash
cd sim
python cmp_all.py u100_full                       # 用随仓库发布的 vec_u100_full.npz
python cmp_all.py tone  <log> <spec> <smem>       # 需要先有仿真 dump 与 vec_tone.npz
```

`cmp_all.py` 需要两样输入：xsim 日志（含 `### DONE` 行）与谱 dump。它打印 `### FIELD MATCH/MISMATCH`
与逐 bin 的相等/差值统计。**注意**：除 `u100_full` 外的 `vec_*.npz` 未随仓库发布（见 §4 已知缺口）。

---

## 3 六个坑

### ① ROM 文件找不到，综合"成功"但 ROM 全 0

`$readmemh` 找不到文件时**不报 error**，只报

```
CRITICAL WARNING: [Synth 8-4445] cannot open file ...
```

综合照常完成、比特流照常生成、板子照常启动、串口照常有报文——只是激励全零，谱也全零。
这个坑吃掉过一个完整的晚上。**判据**：综合日志搜 `8-4445`，一个都不许有。

### ② `CLK2_FREQ_MHZ=125` 是工程级 define，不是参数

UART 分频比在 `rtl/board_top_4lane.v:51-52` 靠这个宏算出来（`localparam CLK_HZ = CLK2_FREQ_MHZ * 1_000_000`）。漏设不会报错，
只会让**每一帧报文的每个字符都是乱码**，而时序、资源、仿真全部正常。
`build_project.tcl` 已经设好；如果你手工建工程，必须自己在 Verilog Define 里加。

### ③ 中文路径会让综合在 MMCM IP 阶段中断

Vivado 2020.2 在中文路径下综合 `clk_wiz_0` 时会中断，报的是 IP 相关的错，看起来像 IP 坏了。
实际是路径编码问题。**克隆到 `D:\_oss_test\` 这类纯英文短路径下再试。**

### ④ 不要用 `synth_design -rtl`

`-rtl` 只做 RTL 级推演，不展开 IP、不做器件映射，得到的资源与时序数字与本仓库所有 L2 指标无关。
要核对指标就走正常的 Run Synthesis / Run Implementation。

### ⑤ 不要用 `xsim -R` 重跑

`xsim tb_sys4_behav -R` 十七秒就能跑完，但它会把已有的 `.wdb` **重写成只剩少量样本的空壳**，
之前记录的内部信号波形全丢。要重跑就用 `scripts/run_sim_wave.tcl`（它先 close_sim 再完整跑）。

### ⑥ 换板要改约束，且要改的是 5 行不是 20 行

`constrs/board_4lane.xdc` 只有 36 行，与板卡相关的只有：

```tcl
create_clock -period 20.000 ... [get_ports sys_clk]     # 1 行：晶振周期
set_property ... PACKAGE_PIN R4  [get_ports sys_clk]    # 4 行：sys_clk / sys_rst_n / uart_txd / led0
set_property ... PACKAGE_PIN U2  [get_ports sys_rst_n]
set_property ... PACKAGE_PIN T6  [get_ports uart_txd]
set_property ... PACKAGE_PIN R2  [get_ports led0]
```

其余是 CFGBVS / 配置电压 / SPI Flash 属性 / 报文 FSM 的多周期约束，与引脚无关。
换板改这 5 行；如果新板晶振不是 50 MHz，MMCM 的 `.xci` 也要在 IP 界面里重配。

---

## 4 已知缺口（不掩盖）

| 缺口 | 影响 | 现状 |
|---|---|---|
| 5 处 `$readmemh` 绝对路径 | 不改就复现不出非零谱 | 待作者修改，见 [`rtl-patch-needed.md`](rtl-patch-needed.md) |
| 除 `u100_full` 外 11 个 `vec_*.npz` 未发布 | `cmp_all.py` 只能对 `u100_full` 直接跑通 | `.mem` 已发布；`.npz` 是定点模型的激励，其中 rand/tone/dc 一族可按 §5 重建，mid/wide/dc780/ultra 的生成脚本未随仓库发布 |
| 无 `.xpr` 入库 | 必须跑一次 `build_project.tcl` | 故意为之：入库的 `.xpr` 会把本机绝对路径写死 |
| 未做综合后 / 实现后时序仿真 | L3 证据不覆盖时序行为 | 报告 §4.7 已列为未验证项 |
| 无 ILA 抓包 | 板级证据是串口报文而非内部波形 | 同上 |

---

## 5 重新生成 ROM 初值

```bash
cd sim
python gen_u100.py && cp iq4_u100_full.mem iq4.mem   # 还原发布状态（满带满功率）
python gen_vec4.py tone               # 换 iq4.mem：rand / tone / dc（单音取 bin 1234，跨直流为双音）
python gen_u100.py                    # 满带 / 贴边最坏向量族：iq4_u100_*.mem + vec_u100_*.npz
python scan7.py 0.05 scan7            # 8 点单音扫描（需 xsim 在 PATH，或设环境变量 XSIM_BAT）
```

> 注意：仓库发布的 `iq4.mem` 是**满带满功率最坏向量**，与 `gen_vec4.py` 的默认（`rand`）不同。
> 直接 `python gen_vec4.py` 会把 `iq4.mem` 换成随机向量，要还原就按上面第一行做。
> `gen_u100.py` 按设计不改写 `iq4.mem`。

`gen_vec4.py` 一次性写出 **5 个规范文件**：`iq4.mem`（2048 × 96 bit）、`hann4.mem`（2048 × 48 bit）、
`wt1..3.mem`（2048 × 36 bit，`exp(-j2πlk/8192)`，l = 1/2/3）。这 5 个是自洽的一套，
**不要混用不同来源的 `.mem`**——合并级的旋转因子表与核内缩放必须同源，混用会出现"谱形对、幅度不对"。

输出目录默认是本脚本所在目录（`sim/`）；要写到别处设环境变量 `VEC_OUT`。
注意 `gen_vec4.py` 的第一个命令行参数是**向量名**，不是路径。
