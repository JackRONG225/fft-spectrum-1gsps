# 常见问题

按被问到的先后排列。每条先给一句结论，再给能核对的位置。

## Q1. 1 GSPS 是采样率吗？板上真有 1 GSPS 的 ADC？

不是。1 GSPS 是**数字吞吐**：4 条 lane 各跑 250 MHz、每拍 4 个复数样点，合计每秒 10⁹ 个样点。
板上没有 1 GSPS ADC，激励是片内 2048 × 96 bit 的 ROM 回放，也没有模拟前端。
见 [metrics.md](metrics.md) A1 与 [README](../README.md) 的口径说明。

## Q2. 为什么要 4 lane？直接用一个 8192 点的核不行吗？

单核 8192 点在 250 MHz 下每拍只出 1 个复数样点，等于 250 MSPS。
要凑到 1 GSPS 就得把时钟提到 1 GHz，而这条路在这颗器件上走不通——
2 lane 的上一代在 600 MSPS 就触顶，1 GHz 单核更无可能，见 [design-evolution.md](design-evolution.md) §2。
改成 4 lane × 2048 点后每拍出 4 个样点，时钟仍是 250 MHz。
合并级再用 9 个 DSP 把四个 2048 点谱拼成 8192 点，见 [architecture.md](architecture.md) §4。

## Q3. 为什么不用 Xilinx FFT IP，而用第三方开源核 + 自己写合并级？

三个原因。一是可再分发：Xilinx FFT IP 生成的 HDL 是许可受限产物，不能进公开仓库，只能留一个 `.xci`
让人自己重生成。二是位精确：第三方核是固定 1/32 缩放、输出确定，才有条件做到逐 bin 逐位对拍。
三是乘法：IP 内部是 4 乘法复乘（20 DSP/核），4 个核就 80 个，加上前级 25 个直接超了 90；
自研 3 乘法把每核压到 15，全链才落到 85。决策表见 [design-evolution.md](design-evolution.md) §3。
这里的"开源核"指源码可得，不是 OSI 意义上的开源——它同样是 CC BY-NC-SA，见 Q10。

## Q4. README 说 BRAM 41/50，可网表里能数出 55 个 Block RAM cell，哪个对？

两个都对，只是口径不同。41 是 RAMB36 等效口径：27 个 RAMB36 加 28 个 RAMB18，两个 RAMB18 折一个 tile，
27 + 14 = 41，所以 41/50 = 82%。55 是原始 BRAM cell 数，27 + 28 = 55。
见 [reproduce.md](reproduce.md) §2 的注与 [metrics.md](metrics.md) B2。

## Q5. 结构下界写 2132 拍，实测 LAT 是 2128 拍，差的 4 拍在哪？

上界是结构推导：一帧采集 1024 + 帧界到 ds_start 3 + pass A 587 + pass B 517 + 锁存与跨域 1 = 2132 个 clk2，
2132 / 125 MHz = 17.056 µs，报告取 17.1 µs。报文 LAT 域实测 2128 拍 = 17.024 µs，60 s 抓包 7858 行恒值。
上界比实测多 4 拍，说明它是贴合实际的估计，不是过估。见 [metrics.md](metrics.md) A4 / A5。

## Q6. 为什么没做综合后仿真、没做 ILA？

两项都没做，报告 §4.7 把它们列为未验证项。原因在这一档的余量：85/90 个 DSP、41/50 个 RAMB，
clk2 只剩 +0.197 ns，插 ILA 要额外占 BRAM 并重新收敛布线。
所以板级证据是串口报文与上板照片，不是内部波形。见 [metrics.md](metrics.md) F 节与
[design-evolution.md](design-evolution.md) §6。

## Q7. 能直接接 ADC 吗？接上就能当频谱仪用？

不能直接接。入口是 96 bit 的 ROM 口，每拍 4 个 lane × 12 bit I/Q，不是 ADC 的串行或并行接口；
要接就得自己写采集前端，含 LVDS 解串、位对齐和跨时钟域。本设计没有这部分，也没有模拟前端与增益校准，
所以即使接上也只能“出谱”，不构成一台频谱仪。见 [architecture.md](architecture.md) §1 与
[design-evolution.md](design-evolution.md) §6。

## Q8. 换一块板子要改什么？

改 5 行约束：1 行时钟周期，4 行引脚（`sys_clk` / `sys_rst_n` / `uart_txd` / `led0`），
都在 `constrs/board_4lane.xdc` 里。若新板晶振不是 50 MHz，MMCM 的 `ip/clk_wiz_0.xci` 还要在 IP 界面重配。
见 [reproduce.md](reproduce.md) 坑⑥。

## Q9. 仓库里为什么没有 `.xpr`？我怎么快速打开工程？

故意不入库。`.xpr` 会写死建工程那台机器的绝对路径（`Project Path=` 字段），别人打开就是坏的。
跑一次 `vivado -mode batch -source scripts/build_project.tcl`，工程生成在 `_proj/fft_spectrum_1gsps.xpr`，
用 Vivado 打开即可；见 [reproduce.md](reproduce.md) §4。

## Q10. 能商用吗？如果我改了自己的部分，能不能闭源？

不能商用。仓库整体是 CC BY-NC-SA 2.0，NonCommercial 条款排除商业使用。
也不能改了闭源：ShareAlike 要求衍生作品按同一许可发布。
之所以是这个许可，不是作者故意卡人——仓库内含第三方 FFT 核，上游本来就是 CC BY-NC-SA 2.0，
ShareAlike 把整体带成了同一许可。要商用只能单独谈授权。
见 [LICENSE](../LICENSE)、[NOTICE](../NOTICE) 与 [README](../README.md) 的许可段。

## Q11. 源码里有中文注释，Vivado 会不会读不了？

能读。Vivado 按 UTF-8 读源文件；`rtl/` 下带中文注释的是 `board_top_4lane`、`ds4`、`mag_sq24`、
`report_fmt4`、`sys4_top`、`uart_tx` 六个，从本仓库 clone 出的副本综合实测通过（`SYNTH_84445_COUNT 0`、
`SYNTH_DSP 85`），行为仿真见 [metrics.md](metrics.md) D6。
真正的坑不在 RTL，在 Tcl：`scripts/` 下 5 个 `.tcl` 全部是纯 ASCII，一个中文字都没有。
因为 Tcl 解析器在非 UTF-8 代码页下遇到中文会报 `missing close-brace` 这类语法错，看着像脚本写坏了，
实际是编码问题；这些脚本的调用方式见 [reproduce.md](reproduce.md) §2。

## 去哪找更多

- 仓库总览： [README](../README.md)
- 每个数字的出处： [metrics.md](metrics.md)
- 三步复现、六个坑、已知缺口： [reproduce.md](reproduce.md)
- 64 页设计报告（中文）： [design-report.pdf](design-report.pdf)

跑不通请开 issue，把 `runme.log` 里 `8-4445` 那几行贴上来。
