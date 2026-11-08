# sim/ 是什么

| 文件 | 作用 |
|---|---|
| `tb_sys4.v` | 行为级 testbench。逐拍校验 bin 轴（`k0 = bitrev11(slot)`）与写地址解码，末态打印 `TB_END` |
| `iq4.mem` | 4 lane × 12 bit I/Q 激励，2048 行 × 96 bit。**发布的是满带满功率向量**（与 `iq4_u100_full.mem` 字节相同，md5 一致） |
| `hann4.mem` | 4 lane 的 Hann 窗系数，2048 × 48 bit |
| `wt1.mem` `wt2.mem` `wt3.mem` | 合并级三张旋转因子表，2048 × 36 bit，`exp(-j2πlk/8192)`，l = 1/2/3 |
| `model4.py` | 全链定点模型（位精确：13 bit 截位平方、24 bit 饱和、`>>2` 合并饱和） |
| `cmp_all.py` | 逐 bin 对拍：字段级 + 8192 bin 谱 + smem，打印 `### FIELD MATCH` / `### SPEC` / `### SMEM` |
| `gen_vec4.py` | 生成上面 5 个规范 `.mem`；`argv[1]` 是向量名（rand / tone / dc） |
| `gen_u100.py` | 满带与贴边最坏向量族，附 `vec_u100_*.npz` |
| `scan7.py` | 8 点单音扫描，缺陷 10 那类索引错位的安全网 |
| `vec_u100_full.npz` | `iq4.mem` 对应的定点模型输入，供 `cmp_all.py u100_full` 直接跑 |

## 用法

```bash
# 逐 bin 对拍（需要一份含 ### DONE 的 xsim 日志与谱 dump）
python cmp_all.py u100_full <log> <spec_dump.txt> <smem_rtl.txt>

# 重建 ROM 初值（5 个文件成套生成，别混用来源）
python gen_vec4.py tone      # 注意：会覆盖 iq4.mem

# 要还原仓库发布时的 iq4.mem（满带满功率），用这个，它不动 iq4.mem：
python gen_u100.py && cp iq4_u100_full.mem iq4.mem

# 8 点单音扫描（xsim 需在 PATH，或设 XSIM_BAT）
python scan7.py 0.05 scan7
```

## 两个约定

1. **`iq4.mem` 发布的是最坏向量，不是 `gen_vec4.py` 的默认值。**
   直接 `python gen_vec4.py`（无参数，默认 `rand`）会把 `iq4.mem` 换成随机向量。
   要回到发布状态：`python gen_u100.py` 后把 `iq4_u100_full.mem` 拷成 `iq4.mem`。
   `gen_u100.py` 按设计不改写 `iq4.mem`。
2. **`.mem` 必须成套。** 合并级旋转因子表与核内缩放同源，混用不同来源的 `.mem` 会出现
   "谱形对、幅度不对"——这种错最难查。
3. **不要混用「4 乘法版」与「3 乘法版」的向量。** 2992 组向量那项证据是两者的**逐位差**，
   不是 2992 个频谱用例。

除 `vec_u100_full.npz` 外的 `.npz` 未随仓库发布；`.mem` 是 RTL 需要的部分，已全部发布。
