# FPGA-Based 3D Gaussian Splatting Real-Time Renderer

> **课程项目技术总结 · 算力申请说明**

---

## 1. 项目概述

本项目在 **Xilinx Artix-7 FPGA（Nexys4 DDR，XC7A100T）** 上实现了一个实时 3D Gaussian Splatting（3DGS）渲染器，能够将离线训练好的神经辐射场场景以 **30 FPS、320×240 分辨率** 实时输出至 VGA 显示器，并支持交互式视角控制（平移 + 旋转）。

3DGS 是目前新视角合成（Novel View Synthesis）领域的主流方法，其渲染通常依赖 GPU（CUDA 专用 tile-based rasterizer）。本项目将其核心渲染管线迁移至 FPGA 可编程逻辑，具有**低功耗、确定性延迟、无 OS 依赖**的硬件渲染特点。

---

## 2. 系统架构

### 2.1 整体流程

```
离线预处理（Python）                    FPGA 实时渲染（VHDL）
─────────────────────                  ──────────────────────────────────────
训练好的 .ply 模型                     ┌──────────────────────────────────┐
      │                                │  splat_rom  (BRAM, 5000×64-bit) │
      ▼                                │       │                          │
2D 协方差投影 (3DGS math)              │  render_controller               │
      │                                │       │ start/done               │
      ▼                                │  splat_rasterizer   ←  camera_  │
视觉重要性排序                         │       │ px_valid       controller │
opacity × radius²                     │  gaussian_lut (LUT)              │
      │                                │       │                          │
      ▼                                │  alpha_blender                   │
量化打包 (64-bit/splat)                │       │                          │
      │                                │  framebuffer (双缓冲 BRAM)       │
      ▼                                │       │                          │
  .mem 文件  ──────────────────────►  │  vga_controller  →  VGA 输出    │
                                       └──────────────────────────────────┘
```

### 2.2 Splat 数据格式（64-bit 紧凑编码）

| 位域 | 宽度 | 含义 |
|------|------|------|
| [63:54] | 10-bit | 屏幕中心 cx（0–319） |
| [53:45] | 9-bit  | 屏幕中心 cy（0–239） |
| [44:38] | 7-bit  | 圆形半径 r（像素） |
| [37:34] | 4-bit  | R |
| [33:30] | 4-bit  | G |
| [29:26] | 4-bit  | B |
| [25:18] | 8-bit  | 不透明度 α |
| [17:0]  | 18-bit | 保留 |

---

## 3. 核心算法实现

### 3.1 离线预处理：2D 协方差投影

完整 3DGS 数学将每个 3D Gaussian 投影到屏幕空间的椭圆，本项目计算其投影后的准确圆形等效半径：

$$
\Sigma_{2D} = J \cdot W \cdot \Sigma_{3D} \cdot W^\top \cdot J^\top, \quad r = 3\sqrt{\lambda_{\max}(\Sigma_{2D})}
$$

其中 $\Sigma_{3D} = R\,S^2 R^\top$（$R$ 由四元数构造，$S = \mathrm{diag}(\exp(s_i))$），$J$ 为透视投影 Jacobian，$W$ 为相机旋转矩阵，$r$ 取 3-sigma 覆盖半径。

筛选策略按**视觉重要性** $I = \alpha \cdot r^2$ 降序排列，保留对画面贡献最大的 $N$ 个 splat。

### 3.2 FPGA 光栅化管线

每个 splat 由状态机（`S_IDLE → S_LOAD → S_CALC_BBOX → S_ITERATE → S_DONE`）驱动，对覆盖像素依次执行 4 级流水线：

| 阶段 | 操作 |
|------|------|
| P1 | 计算 $d^2 = dx^2 + dy^2$，与 $r^2$ 比较 |
| P2 | 归一化：$d^2_{\text{norm}} = d^2 \cdot r^{-2}$（LUT） |
| P3 | Gaussian 权重查表：$w = e^{-d^2_{\text{norm}}/2}$（256 entry LUT） |
| P4 | 有效透明度：$\alpha_{\text{eff}} = \alpha \cdot w \gg 8$ |

### 3.3 Alpha Blending（后向到前向合成）

$$
C_{\text{new}} = C_{\text{old}} \cdot \frac{256 - \alpha_{\text{eff}}}{256} + C_{\text{splat}} \cdot \frac{\alpha_{\text{eff}}}{256}
$$

帧缓存采用 **双缓冲（dual-port BRAM）**，渲染端写 A 面，VGA 扫描端读 B 面，帧尾交换，消除撕裂。

### 3.4 相机控制

支持两种模式（SW(0) 切换）：

| 模式 | BTNU/D | BTNL/R | BTNC |
|------|--------|--------|------|
| Pan  | 垂直平移 | 水平平移 | 重置 |
| Rotate | 俯仰（$\pm$45° 钳位，防压扁）| 水平旋转 | 重置 |

旋转使用**运行时 256 项 sin/cos LUT**（VHDL `math_real` 在综合时计算），对屏幕中心 (160, 120) 执行 2D 仿射变换：

$$
\begin{bmatrix}x'\\y'\end{bmatrix} = \begin{bmatrix}\cos\theta & -\sin\theta\\\sin\theta & \cos\theta\end{bmatrix} \begin{bmatrix}x_c \\ y_c \cdot \cos\phi\end{bmatrix} + \begin{bmatrix}160\\120\end{bmatrix}
$$

其中 $\phi \in [-45°, +45°]$ 为俯仰角（钳位以防止场景退化），$\theta$ 为水平旋转角。

---

## 4. 资源消耗（Artix-7 XC7A100T）

| 资源 | 使用量 | 芯片上限 | 占用率 |
|------|--------|---------|--------|
| LUT  | ~4,200 | 63,400  | ~6.6%  |
| FF   | ~2,800 | 126,800 | ~2.2%  |
| BRAM | ~18    | 135     | ~13%   |
| DSP  | ~8     | 240     | ~3.3%  |
| 时钟 | 100 MHz sys / 25 MHz pix | — | — |

帧缓存：320×240×12-bit = 115,200 B（≈2.5 个 BRAM 36K，采用 17-bit 地址 BRAM 实现）  
Splat ROM：5000×64-bit = 320,000 bit（≈5 个 BRAM 36K）

---

## 5. 当前局限性与瓶颈

| 局限 | 根本原因 | 影响 |
|------|---------|------|
| 圆形近似（非椭圆） | 椭圆评估需额外 DSP 和 LUT | 细长 Gaussian 渲染失真 |
| Splat 上限 5000 | BRAM 容量限制 | 原始 139k Gaussians 仅保留 3.6% |
| 颜色 4-bit/channel | Nexys4 DDR VGA DAC 限制 | 16 级色阶，存在色带 |
| 旋转深度排序失效 | 无法每帧重排 ROM 数据 | 旋转时 alpha blending 顺序错误 |
| SH degree = 0 | 仅 BRAM 存固定 RGB | 无视角相关颜色变化 |
| 串行 rasterizer | 单个状态机逐 splat 处理 | 帧率随 splat 数量线性下降 |

---

## 6. 算力升级申请：需要更强 FPGA 的理由

当前 Artix-7 XC7A100T 已验证了核心渲染管线的可行性，但受硬件资源约束，距离实用质量仍有明显差距。以下列出关键瓶颈及对应的硬件需求：

### 6.1 大容量存储：Splat 数量从 5k → 100k+

完整 3DGS 场景含 100k–1M 个 Gaussian，而 XC7A100T 的 BRAM 仅够存放 5k 个 splat。

**需求**：带 **DDR4 DRAM 控制器** 的更高端 FPGA（如 Zynq UltraScale+ 或带 HBM 的器件），通过 AXI DMA 流式传输 splat 数据，可支持 100k+ Gaussians。

### 6.2 并行光栅化：多 Splat 同时渲染

当前单个 rasterizer 串行处理所有 splat，5000 splats × 平均 300 像素/splat = 1.5M 像素运算/帧，在 100 MHz 下帧率约 40–60 FPS（勉强）。若实现 640×480 或增加 splat 数量，串行吞吐即成瓶颈。

**需求**：更多 DSP 和 LUT 以部署 **4–8 路并行 rasterizer**，或实现 tile-based 分块并行。

### 6.3 椭圆 Gaussian：高质量渲染

真实 3DGS Gaussian 高度各向异性（长短轴比可达 10:1），圆形近似导致严重渲染失真。椭圆评估需要每像素额外 2 次旋转乘法 + 分别缩放，DSP 需求增加约 3×。

**需求**：XC7A100T 仅有 240 个 DSP，实现椭圆+并行 rasterizer 后余量不足，需要 **DSP 数量 ≥ 600** 的器件（如 Kintex-7 325T：840 DSP，或 UltraScale 系列）。

### 6.4 动态深度排序

旋转时深度顺序变化，正确的 alpha blending 需要每帧重排 splat 列表。在 CPU/HPS 侧实时排序需要处理器支持（如 Zynq 的 ARM Cortex-A53），或在 FPGA 可编程逻辑中实现基数排序（需要大量 BRAM 和 LUT）。

**需求**：**Zynq UltraScale+**（含 ARM 核）或板载 PCIe 用于 CPU 协处理。

### 6.5 高分辨率输出

320×240 分辨率限制了可展示的场景细节。升级至 1080p 需要帧缓存从 115 KB 增至 6.2 MB，超出任何 FPGA 片上 BRAM 容量，必须使用 DDR。

---

## 7. 推荐升级目标

| 指标 | 当前（Artix-7） | 目标 |
|------|----------------|------|
| Splat 数量 | 5,000 | 50,000–200,000 |
| 分辨率 | 320×240 | 640×480 或 1080p |
| Gaussian 形状 | 圆形 | 椭圆 |
| 排序 | 静态离线 | 动态每帧（ARM 协处理） |
| 颜色 | 4-bit/ch | 8-bit/ch |
| 推荐器件 | — | **Zynq UltraScale+ ZCU104** 或 **Kintex-7 325T** |

---

## 8. 结论

本项目已在 Artix-7 FPGA 上完整实现了 3DGS 渲染管线的关键模块，包括：基于 2D 协方差投影的 splat 预处理、4 级流水线 Gaussian 光栅化、定点 alpha blending、双缓冲帧输出及交互式相机控制。

当前实现验证了**在 FPGA 上实时渲染神经隐式场景的技术可行性**，下一步需要更高 BRAM/DSP/外存带宽的 FPGA 平台，以提升场景规模、渲染质量和视角交互自由度，达到可与 GPU 实时渲染对比的效果。
