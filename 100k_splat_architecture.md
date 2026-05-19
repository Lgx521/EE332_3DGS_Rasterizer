# 在 Artix-7 XC7A100T 上渲染 100k 椭圆 Gaussian 的极限优化方案

## 核心思路

> **DDR2 外存 + 流式读取 + 逆协方差椭圆 + 视锥裁剪 + 前到后 early termination**

Nexys4 DDR 板载 **128 MB DDR2 SDRAM**（16-bit, 有效带宽 ~1.3 GB/s），足以存放百万级 splat 数据。通过流式架构，FPGA 只需极少 BRAM 做缓冲，即可顺序处理任意数量的 splat。

---

## 1. 资源预算分析

| 资源 | Artix-7 XC7A100T 总量 | 当前设计占用 | 剩余可用 |
|------|----------------------|-------------|----------|
| LUT | 63,400 | ~4,200 | ~59,200 |
| FF | 126,800 | ~2,800 | ~124,000 |
| BRAM 36K | 135 | ~18 | ~117 |
| DSP48 | 240 | ~8 | ~232 |
| DDR2 | 128 MB | 0 | **128 MB** |

100k splat × 64-bit = **800 KB**，仅占 DDR2 的 0.6%。带宽需求：800 KB × 30 FPS = **24 MB/s**，仅占 DDR2 理论带宽的 1.8%。

**结论：存储和带宽均不是瓶颈，计算吞吐量才是。**

---

## 2. 时间预算分析

100 MHz 时钟，30 FPS → 每帧 **3.33M 周期**。

若逐一渲染 100k splat，每个 splat 平均仅有 **33 个时钟周期** 的预算。以平均半径 8px 计，椭圆覆盖面积 ≈ π×8×4 ≈ 100 像素，远超 33 周期。

**必须通过以下策略将每帧实际处理量降至 ~10k–15k splat：**

---

## 3. 关键优化策略

### 3.1 DDR2 流式存储架构

```
DDR2 (128 MB)                      FPGA 逻辑
┌───────────────────┐              ┌─────────────────────────────┐
│ Splat Array       │  AXI4 burst  │  FIFO 缓冲 (64×64-bit)     │
│ 100k × 64-bit    │─────────────►│       │                     │
│ 800 KB            │              │  Cull Unit (视锥+重要性)    │
│                   │              │       │ pass/reject         │
│ Tile Index Table  │              │  Rasterizer Pipeline        │
│ (可选)            │              │       │                     │
└───────────────────┘              │  Alpha Blender → Framebuffer│
                                   └─────────────────────────────┘
```

- 使用 Xilinx **MIG (Memory Interface Generator)** IP 访问 DDR2
- AXI4 burst read，每次预取 64 个 splat 到片上 FIFO
- Rasterizer 从 FIFO 读取，DDR2 访问延迟被完全隐藏

### 3.2 逆协方差椭圆表示（避免 per-pixel 三角函数）

**关键创新**：不存储 (r_major, r_minor, angle)，而是直接存储 **2×2 逆协方差矩阵的 3 个系数**：

$$
d^2_{\text{norm}} = A \cdot dx^2 + B \cdot dx \cdot dy + C \cdot dy^2
$$

其中 $A, B, C$ 是离线预计算的定点数，直接从 2D 投影协方差矩阵 $\Sigma_{2D}^{-1}$ 量化而来。

**硬件优势**：

| | 圆形 Gaussian | 椭圆 (r, angle) | **椭圆 (A,B,C 逆协方差)** |
|--|---|---|---|
| 每像素乘法 | 2 | 6（含 sin/cos 旋转） | **3** |
| 每像素加法 | 1 | 4 | **2** |
| 需要角度 LUT | 否 | 是 | **否** |
| DSP 需求 | 2 | 6 | **3** |

仅比圆形多 1 个 DSP 乘法器，但获得完整椭圆渲染能力！

### 3.3 紧凑 64-bit 椭圆 Splat 格式

```
[63:54]  cx          10 bits   屏幕坐标 x (0–319)
[53:45]  cy           9 bits   屏幕坐标 y (0–239)
[44:40]  r_bbox       5 bits   包围盒半径 (0–31, ×2 → max 62px)
[39:36]  R            4 bits   红色
[35:32]  G            4 bits   绿色
[31:28]  B            4 bits   蓝色
[27:22]  alpha        6 bits   不透明度 (64 级)
[21:15]  cov_A        7 bits   逆协方差 A (unsigned, scale 128)
[14:8]   cov_C        7 bits   逆协方差 C (unsigned, scale 128)
[7:1]    cov_B        7 bits   逆协方差 B (signed, scale 128)
[0]      reserved     1 bit
```

- `r_bbox` 用于快速生成包围盒（AABB），无需从 A/B/C 反算
- `cov_A, cov_B, cov_C` 已预归一化：当 $d^2_{\text{norm}} = 128$ 时像素在椭圆边界
- 总宽度仍为 64-bit，与 DDR2 burst 对齐

### 3.4 视锥裁剪单元（Cull Unit）

在 splat 进入 rasterizer 前，**1 个周期** 内判定是否需要渲染：

```vhdl
-- 1-cycle rejection test
cull <= '1' when
    (cx + r_bbox < view_x_min) or (cx - r_bbox > view_x_max) or
    (cy + r_bbox < view_y_min) or (cy - r_bbox > view_y_max) or
    (alpha < ALPHA_THRESHOLD);  -- skip nearly transparent
```

裁剪效率：
- 典型场景中，100k splat 约 **60–80% 在屏幕外或极低贡献**
- 裁剪后实际进入 rasterizer 的仅 **20k–40k** 个

### 3.5 前到后渲染 + 像素级 Early Termination

**改变排序方向**：从 back-to-front 改为 **front-to-back**，使用累加 transmittance：

$$
C_{\text{new}} = C_{\text{old}} + T \cdot \alpha_{\text{eff}} \cdot C_{\text{splat}}, \quad T_{\text{new}} = T \cdot (1 - \alpha_{\text{eff}})
$$

当 $T < \epsilon$（如 1/256），该像素已饱和，后续所有 splat 对该像素 **不再写入**。

**硬件实现**：为每行/每 tile 维护 transmittance bitmap（1-bit per pixel 表示是否已饱和）。在密集场景中，前 30% 的 splat 即可使 80%+ 像素饱和，后续 splat 的有效像素覆盖急剧减少。

有效像素处理量估算：

| 策略 | 有效 splat 数 | 有效像素/splat | 总像素操作 | 帧时间 (100MHz) |
|------|-------------|-------------|-----------|----------------|
| 无优化 | 100,000 | ~100 | 10M | 100 ms (10 FPS) |
| + 视锥裁剪 | ~30,000 | ~100 | 3M | 30 ms (33 FPS) |
| + early termination | ~30,000 | ~30 | **900k** | **9 ms (>60 FPS)** |

### 3.6 可选：Tile-Based 进一步优化

将 320×240 分为 20×15 = 300 个 **16×16 tile**：

- 离线为每个 tile 生成 splat 索引列表，存入 DDR2
- 每个 tile 独立渲染，仅处理重叠的 splat
- Tile 本地 framebuffer：16×16×12-bit = 3072 bit（极少 BRAM）
- 无需维护全屏 transmittance buffer

优点：
- 减少无效像素评估（splat 只在其覆盖的 tile 内处理）
- 适合小 BRAM 容量

缺点：
- 视角改变时需重建 tile 列表（可由简单硬件流式判定）
- 增加少量控制逻辑

---

## 4. 修改后的系统架构总图

```
┌─────────────────────────────────────────────────────────────────┐
│                         FPGA (XC7A100T)                         │
│                                                                 │
│  ┌──────────┐    ┌───────────┐    ┌───────────────────────┐    │
│  │ MIG DDR2 │    │ 64-deep   │    │  Cull Unit            │    │
│  │Controller│───►│ FIFO      │───►│  (1-cycle reject)     │    │
│  │ (AXI4)   │    │ (BRAM)    │    │  视锥 + α threshold   │    │
│  └──────────┘    └───────────┘    └──────────┬────────────┘    │
│       │                                       │                 │
│       │  ┌────────────────────────────────────▼──────────────┐  │
│       │  │  Elliptical Splat Rasterizer (4-stage pipeline)   │  │
│       │  │  P1: dx², dy², dx·dy                              │  │
│       │  │  P2: d²_norm = A·dx² + B·dx·dy + C·dy²           │  │
│       │  │  P3: Gaussian LUT → weight                        │  │
│       │  │  P4: α_eff = α × weight; T-test (early term)     │  │
│       │  └──────────────────────────┬────────────────────────┘  │
│       │                             │                           │
│       │  ┌──────────────────────────▼────────────────────────┐  │
│       │  │  Alpha Blender (front-to-back accumulation)       │  │
│       │  │  C += T × α_eff × color;  T *= (1 - α_eff)       │  │
│       │  └──────────────────────────┬────────────────────────┘  │
│       │                             │                           │
│       │  ┌──────────────────────────▼────────────────────────┐  │
│       │  │  Framebuffer (double-buffer, BRAM)                │  │
│       │  │  320×240×12-bit                                   │  │
│       │  └──────────────────────────┬────────────────────────┘  │
│       │                             │                           │
│  ┌────┼─────────────────────────────▼────────────────────────┐  │
│  │ Camera Controller │  VGA Timing  │  VGA Output (4-bit/ch) │  │
│  └───────────────────┴──────────────┴────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                         DDR2 SDRAM
                        (128 MB, 板载)
```

---

## 5. 资源消耗估算（优化后）

| 模块 | LUT | FF | BRAM 36K | DSP48 |
|------|-----|-----|---------|-------|
| MIG DDR2 Controller | ~3,000 | ~4,000 | 3 | 0 |
| Splat FIFO (64×64-bit) | ~200 | ~300 | 1 | 0 |
| Cull Unit | ~150 | ~100 | 0 | 0 |
| Elliptical Rasterizer | ~2,500 | ~1,500 | 2 | 6 |
| Gaussian LUT | ~100 | ~100 | 1 | 0 |
| Alpha Blender (F2B) | ~800 | ~600 | 0 | 4 |
| Transmittance Buffer | ~200 | ~100 | 2 | 0 |
| Framebuffer (double) | ~300 | ~200 | 10 | 0 |
| VGA + Camera Ctrl | ~1,500 | ~1,200 | 2 | 2 |
| **总计** | **~8,750** | **~8,100** | **~21** | **~12** |
| **占用率** | **13.8%** | **6.4%** | **15.6%** | **5%** |

**结论：所有资源占用率 < 20%，XC7A100T 完全足够。**

---

## 6. 离线预处理改动

`preprocess_ply.py` 需额外输出逆协方差系数：

```python
# 计算 2D 逆协方差 (从 Sigma2d)
det = Sigma2d[0,0]*Sigma2d[1,1] - Sigma2d[0,1]**2
inv_A = Sigma2d[1,1] / det   # 对应 dx² 系数
inv_C = Sigma2d[0,0] / det   # 对应 dy² 系数
inv_B = -2*Sigma2d[0,1] / det  # 对应 dx·dy 系数（注意符号）

# 归一化：使得椭圆 3-sigma 边界上 d²_norm = 128
scale_factor = 128.0 / 9.0    # 3² = 9 for 3-sigma
A_q = clamp(round(inv_A * scale_factor), 0, 127)
C_q = clamp(round(inv_C * scale_factor), 0, 127)
B_q = clamp(round(inv_B * scale_factor), -64, 63)
```

排序改为**前到后（depth ascending）**以配合 early termination。

---

## 7. 实现路线图

| 阶段 | 工作内容 | 预计周期 |
|------|---------|---------|
| Phase 1 | 集成 MIG DDR2 IP，实现 AXI4 读取 + FIFO 流式传输 | 1 周 |
| Phase 2 | 修改 splat 格式为椭圆逆协方差，修改 preprocess_ply.py | 2 天 |
| Phase 3 | 修改 rasterizer 为椭圆评估 (A·dx²+B·dx·dy+C·dy²) | 3 天 |
| Phase 4 | 实现前到后 alpha blending + transmittance early termination | 3 天 |
| Phase 5 | 实现 Cull Unit + 视锥裁剪 | 1 天 |
| Phase 6 | 集成测试、调优帧率 | 3 天 |

---

## 8. 性能预测

| 场景 | Splat 总数 | 裁剪后 | Early Term 后有效像素 | 预计帧率 |
|------|-----------|--------|---------------------|---------|
| 单物体居中 | 100,000 | ~15,000 | ~800k | **>60 FPS** |
| 桌面场景 | 100,000 | ~30,000 | ~1.5M | **~40 FPS** |
| 全景 (最坏) | 100,000 | ~60,000 | ~4M | **~15 FPS** |

---

## 9. 总结

在不更换 FPGA 的前提下，通过以下 5 项关键优化，可在 **Artix-7 XC7A100T + 128 MB DDR2** 上实现 100k 椭圆 Gaussian 实时渲染：

1. **DDR2 外存**：突破 BRAM 容量限制，存储 100k+ splat
2. **逆协方差直存**：仅 3 次乘法/像素实现完整椭圆，无需三角函数
3. **流式裁剪**：1 周期视锥判定，60–80% splat 免计算
4. **前到后 Early Termination**：像素饱和后跳过，有效工作量降低 70%+
5. **紧凑 64-bit 格式**：DDR2 带宽利用率仅 1.8%，无瓶颈

**全部资源占用率 < 20%，无需更换 FPGA。**
