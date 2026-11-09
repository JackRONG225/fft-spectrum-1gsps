# 图

全部从 64 页设计报告 `docs/design-report.pdf` 按图题裁出（pymupdf，220 dpi），未重绘。

| 文件 | 报告图号 | 页 | 讲什么 |
|---|---|---|---|
| `fig1-1_architecture.png` | 图 1-1 | 5 | 系统总体结构与两时钟域划分（250 MHz / 125 MHz，只跨谱 RAM 与单比特帧标志） |
| `fig2-3_radix4_merge.png` | 图 2-3 | 12 | 4 路 radix-4 合并与 bin 映射（四个同余类，不是一个连续四段） |
| `fig4-1_rtl_dataflow.png` | 图 4-1 | 23 | RTL 数据流与模块划分 |
| `fig4-2_capture_timing.png` | 图 4-2 | 25 | 连续捕获下的帧节拍、双引擎与 `max(PA,PB)` 预算 |
| `fig4-4_spectrum_vs_model.png` | 图 4-4 | 31 | 谱快照与定点模型对比 |
| `fig5-2_smooth_spec.png` | 图 5-2 | 46 | 三组向量的平滑谱与报文字段对应 |

用图时请连版权与许可见仓库根目录 `LICENSE`（CC BY-NC-SA 2.0）。
