# gen/ 是什么

这里 10 个 VHDL 是**生成件**，不是手写 RTL：

- `fft2048.vhd` + `fft2048_sub8/16/32/64.vhd` —— 2048 点 FFT 的分解结构与各级子模块
- `twiddleRom2048.vhd` / `twiddleRom64.vhd` —— 旋转因子表
- `twiddleGenerator8/16/32.vhd` —— 旋转因子发生器

它们原本由第三方 FFT 核自带的 codegen 生成，目录结构上是 `03_GEN/fft2048/` 与 `03_GEN/twiddle/`，
本仓库拍平了（文件名无冲突），编译顺序由 `scripts/build_project.tcl` 里的
`update_compile_order` 自动排定。

**不要手改这些文件。** 参数变了就重新生成，否则与你手写的顶层会出现位宽或槽序不一致——
这类错误只在逐 bin 对拍时暴露，且表现是"谱形看起来还对"。

配套的 ROM 初值（`iq4.mem` / `hann4.mem` / `wt1..3.mem`）由 `sim/gen_vec4.py` 生成，
与本目录的表同源。两者必须成套使用。
