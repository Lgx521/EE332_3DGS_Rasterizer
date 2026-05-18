# 最小可跑版 FPGA Gaussian Splatting Renderer 核心设计想法

## 1. 项目目标

本项目目标不是在 FPGA 上完整复现官方 3D Gaussian Splatting，也不是实现训练流程，而是实现一个**最小可跑的 FPGA Gaussian Splatting 渲染 demo**。

核心目标是：

> 将离线训练好的 3D Gaussian 场景经过预处理后，以低分辨率、少量高斯、固定颜色的形式在 FPGA 上实时渲染显示。

该 demo 重点验证以下能力：

1. FPGA 可以从高斯参数数据中生成屏幕上的 splat 图像；
2. FPGA 可以完成基本的像素覆盖计算与 alpha blending；
3. 最终结果可以通过 VGA/HDMI 输出到显示器；
4. 系统能够展示一个具有三维结构感的简化 3DGS 场景。

本项目不追求照片级画质，而追求**架构清晰、硬件可实现、效果可展示**。

---

## 2. 设计定位

本项目可以定位为：

> A minimal FPGA-based Gaussian Splatting rasterizer for compressed 3DGS scenes.

中文可以表述为：

> 面向压缩 3DGS 场景的最小化 FPGA 实时 splatting 渲染器。

它与完整 3DGS 的区别如下：

| 项目 | 完整 3DGS | 最小可跑 demo |
|---|---|---|
| 训练 | GPU / PyTorch 完成 | 不在 FPGA 上实现 |
| Gaussian 数量 | 几十万到百万级 | 5k～20k |
| 颜色表示 | Spherical Harmonics | 固定 RGB，SH degree = 0 |
| 分辨率 | 720p / 1080p 或更高 | 320×240 |
| 相机 | 自由交互 | 固定轨迹或简单控制 |
| 排序 | GPU tile sorting | 离线或 CPU/PS 端完成 |
| FPGA 任务 | 不适用 | rasterization + blending + display |
| 目标 | 高质量新视角合成 | 可运行的硬件渲染 demo |

---

## 3. 整体思路

完整 3D Gaussian Splatting 的渲染流程通常包括：

```text
3D Gaussian 参数
    ↓
相机空间变换
    ↓
3D Gaussian 投影到屏幕
    ↓
得到 2D 椭圆 splat
    ↓
按 tile / depth 排序
    ↓
逐像素计算 Gaussian 权重
    ↓
alpha blending
    ↓
输出图像
```

在最小可跑 demo 中，为了降低 FPGA 复杂度，将流程拆成**离线预处理**和**FPGA 实时渲染**两部分。

```text
离线端 / CPU 端
    读取训练好的 .ply
    量化 Gaussian 参数
    固定 SH degree = 0
    预计算相机轨迹
    可选：预投影、预排序、预分 tile
    生成 FPGA 可读数据

FPGA 端
    读取 Gaussian / splat 数据
    遍历 splat 覆盖区域
    计算像素权重
    执行 alpha blending
    写入 framebuffer
    VGA/HDMI 输出
```

核心原则是：

> 能离线做的复杂工作尽量离线做，FPGA 只保留最能体现硬件渲染价值的 rasterization 与 blending。

---

## 4. 最小版本的核心假设

为了让 demo 更容易跑通，第一版采用以下假设：

1. **场景离线训练**
   - 使用官方 3DGS 或其他工具在 PC/GPU 上训练；
   - FPGA 只读取训练后的高斯参数，不参与训练。

2. **Gaussian 数量有限**
   - 第一版建议控制在 5k～20k 个 Gaussian；
   - 可以从完整场景中筛选 opacity 较高、贡献较大的 Gaussian。

3. **颜色固定**
   - 不使用高阶 spherical harmonics；
   - 每个 Gaussian 只保留一个固定 RGB；
   - 这样可以避免 FPGA 上计算视角相关颜色。

4. **低分辨率输出**
   - 建议使用 320×240；
   - 后续可扩展到 640×480。

5. **排序简化**
   - 第一版不在 FPGA 上做复杂 depth sorting；
   - 可以离线按照相机轨迹预排序；
   - 或由 CPU/PS 端每帧完成排序后传给 FPGA。

6. **固定或半固定相机**
   - 第一版可以使用固定相机轨迹播放；
   - 相机路径已知时，可以提前生成每一帧的 splat 数据；
   - 这样最容易保证稳定画面。

---

## 5. 数据表示设计

### 5.1 原始 Gaussian 参数

训练好的 3DGS 通常包含以下参数：

```text
position:     x, y, z
scale:        sx, sy, sz
rotation:     quaternion
opacity:      alpha
color:        RGB or SH coefficients
```

最小 demo 不一定需要把这些完整送进 FPGA。

### 5.2 推荐的最小 FPGA 输入格式

第一版可以选择将 3D Gaussian 离线投影成 2D splat，再送入 FPGA。

每个 splat 可以表示为：

```text
center_x      屏幕中心 x 坐标
center_y      屏幕中心 y 坐标
radius_x      椭圆 x 方向半径，第一版可简化成圆形半径
radius_y      椭圆 y 方向半径
inv_cov_00    2D 高斯二次型参数
inv_cov_01    2D 高斯二次型参数
inv_cov_11    2D 高斯二次型参数
r             颜色 R
g             颜色 G
b             颜色 B
alpha         不透明度
depth         深度，用于排序或调试
```

为了进一步简化，第一版可以把椭圆 splat 简化成圆形 splat：

```text
center_x
center_y
radius
r, g, b
alpha
depth
```

这样每个像素权重可以近似为：

```text
dx = pixel_x - center_x
dy = pixel_y - center_y
d2 = dx * dx + dy * dy
weight = exp(-d2 / radius_scale)
```

如果不想在 FPGA 上计算 `exp`，也可以使用查找表：

```text
d2_norm → weight
```

---

## 6. FPGA 渲染核心

### 6.1 渲染流程

FPGA 端的核心流程如下：

```text
for each frame:
    clear framebuffer

    for each splat in sorted_splat_list:
        read splat parameters

        for y in splat_y_min to splat_y_max:
            for x in splat_x_min to splat_x_max:
                compute dx, dy
                compute weight
                compute effective_alpha = alpha * weight

                read old pixel color and transmittance
                blend new color
                write updated pixel

    scan framebuffer to VGA/HDMI
```

### 6.2 Alpha Blending

采用前向到后向的透明合成公式：

```text
C_new = C_old + T_old * effective_alpha * color
T_new = T_old * (1 - effective_alpha)
```

其中：

```text
C_old: 当前像素已经累积的颜色
T_old: 当前像素剩余透射率
effective_alpha = alpha * weight
```

如果第一版想进一步简化，可以不显式存储 `T`，而采用近似公式：

```text
C_new = C_old * (1 - effective_alpha) + color * effective_alpha
```

这种方式画质不如标准 3DGS，但实现更简单，更容易做出 demo。

---

## 7. 模块划分

最小可跑 demo 可以划分为以下模块。

### 7.1 Python 预处理模块

文件示例：

```text
preprocess.py
```

功能：

1. 读取 `.ply` 高斯模型；
2. 筛选 Gaussian；
3. 固定颜色为 RGB；
4. 根据固定相机或相机轨迹，将 3D Gaussian 投影到 2D；
5. 简化协方差参数；
6. 生成排序后的 splat list；
7. 导出 `.mem` / `.coe` / binary 文件供 FPGA 使用。

### 7.2 Splat Reader

文件示例：

```text
splat_reader.v
```

功能：

1. 从 ROM/BRAM/DDR 中读取 splat 参数；
2. 按顺序送入 rasterizer；
3. 控制一帧内 splat 的起止。

### 7.3 Splat Rasterizer

文件示例：

```text
splat_rasterizer.v
```

功能：

1. 根据 splat 中心和半径生成像素遍历范围；
2. 对每个覆盖像素计算 `dx, dy, d2`；
3. 使用查找表得到 Gaussian 权重；
4. 输出目标像素坐标、颜色和 effective alpha。

### 7.4 Weight LUT

文件示例：

```text
gaussian_lut.v
```

功能：

1. 输入归一化距离；
2. 输出近似 Gaussian 权重；
3. 避免在 FPGA 中直接实现指数函数。

### 7.5 Alpha Blender

文件示例：

```text
alpha_blender.v
```

功能：

1. 读取 framebuffer 中已有颜色；
2. 根据 effective alpha 进行混合；
3. 写回新的像素颜色。

### 7.6 Framebuffer

文件示例：

```text
framebuffer.v
```

功能：

1. 存储当前帧图像；
2. 支持渲染端写入；
3. 支持 VGA/HDMI 扫描端读取；
4. 可以采用双缓冲避免读写冲突。

### 7.7 Display Controller

文件示例：

```text
vga_controller.v
```

功能：

1. 产生 VGA 时序；
2. 从 framebuffer 读取像素；
3. 输出 RGB 与同步信号。

### 7.8 Top Module

文件示例：

```text
top.v
```

功能：

1. 连接所有模块；
2. 管理系统状态；
3. 控制帧开始、帧结束、buffer swap；
4. 对外连接时钟、复位、VGA/HDMI 引脚。

---

## 8. 第一版推荐实现路径

### Step 1：先做纯软件参考渲染器

在 Python 中实现同样的简化 splatting 逻辑：

```text
读取 splat list
逐 splat 遍历像素
查表计算 weight
alpha blending
输出 png
```

目标是先确认：

1. 数据格式正确；
2. 简化后的画面可以接受；
3. 定点化之前的算法逻辑没问题。

### Step 2：做定点化模拟

将 Python 中的 float 运算替换为整数/定点运算：

```text
坐标：Q10.6 或 Q12.4
颜色：8-bit
alpha：8-bit
weight：8-bit
```

目标是确认定点误差不会导致画面严重退化。

### Step 3：导出 FPGA 数据文件

将 splat list 导出为：

```text
splat_data.mem
gaussian_lut.mem
camera_frame_index.mem
```

### Step 4：实现 FPGA rasterizer

先不接真实 3DGS 数据，使用手写的几个 splat 测试：

```text
一个红色 splat
一个绿色 splat
一个蓝色 splat
多个重叠 splat
```

确认 framebuffer 和 blending 正确。

### Step 5：接入真实 splat 数据

把离线处理后的 3DGS splat list 写入 ROM/DDR，让 FPGA 渲染真实场景。

### Step 6：加显示输出

将 framebuffer 接到 VGA/HDMI 控制器，实现显示器实时输出。

---

## 9. 最小 demo 的预期效果

最终画面不会达到完整 3DGS 的照片级效果，而更像：

```text
低分辨率的彩色高斯点云
带有柔和的半透明 splat
可以看出物体轮廓和三维结构
边缘可能有毛刺和模糊
细节比官方 3DGS 少
```

对于单物体场景，例如玩具、杯子、小雕像，效果会比较稳。对于大房间场景，画面可能更模糊，排序错误也更明显。

最推荐的展示形式是：

```text
固定相机轨迹播放一个小物体或桌面场景
```

这样可以提前预处理每一帧，降低 FPGA 端复杂度，同时保证展示效果稳定。

---

## 10. 主要风险与规避方案

### 风险 1：画面太稀疏

原因：

```text
Gaussian 数量太少
splat 半径太小
筛选策略过于激进
```

规避：

```text
增加 Gaussian 数量
放大 splat radius
优先保留 opacity 高、屏幕贡献大的 Gaussian
```

### 风险 2：alpha blending 结果不对

原因：

```text
排序错误
alpha 定点精度太低
混合公式简化过度
```

规避：

```text
第一版使用固定相机轨迹并离线排序
提高 alpha/weight 精度
保存 transmittance buffer
```

### 风险 3：FPGA 带宽不够

原因：

```text
每个 splat 覆盖像素太多
framebuffer 频繁读写
DDR/BRAM 访问冲突
```

规避：

```text
降低分辨率
限制 splat 最大半径
使用 tile-based buffer
使用双缓冲
先从 320×240 开始
```

### 风险 4：指数函数实现复杂

原因：

```text
Gaussian weight 需要 exp
```

规避：

```text
使用 LUT 替代 exp
或者使用分段线性近似
第一版甚至可以用简单 radial falloff 近似
```

---

## 11. 建议的第一版配置

| 参数 | 建议值 |
|---|---|
| 分辨率 | 320×240 |
| Gaussian 数量 | 5k～20k |
| 颜色 | RGB only |
| SH degree | 0 |
| 相机 | 固定轨迹 |
| 排序 | 离线排序 |
| Gaussian 形状 | 第一版可简化为圆形 splat |
| 权重计算 | LUT |
| 输出 | VGA 或 HDMI |
| framebuffer | 双缓冲优先，单缓冲也可先调通 |
| 目标帧率 | 10～30 FPS |

---

## 12. 项目亮点

本 demo 的亮点在于：

1. 将 3DGS 这种通常依赖 GPU 的渲染方法迁移到 FPGA；
2. 通过离线预处理和数据压缩，将复杂 3D 渲染转化为硬件友好的 splat rasterization；
3. 使用定点运算、查找表和流水线结构实现实时渲染；
4. 展示了 FPGA 在图形渲染任务中的可编程硬件并行能力；
5. 相比传统 VGA 小游戏，本项目更接近现代 neural rendering / point-based rendering 的思想。

---

## 13. 后续可扩展方向

如果最小版本跑通，可以继续扩展：

1. 从圆形 splat 扩展到椭圆 splat；
2. 从固定 RGB 扩展到低阶 spherical harmonics；
3. 从离线排序扩展到 FPGA tile sorting；
4. 从固定轨迹扩展到实时相机交互；
5. 从 BRAM 小场景扩展到 DDR 大场景；
6. 从 320×240 提升到 640×480；
7. 加入 tile-based framebuffer cache；
8. 加入 early termination，提高渲染效率；
9. 加入 host-FPGA 通信，实现动态加载场景。

---

## 14. 一句话总结

本项目的核心设计思想是：

> 把完整 3D Gaussian Splatting 中复杂的训练、投影、排序和颜色计算尽量放到离线端完成，让 FPGA 专注于最硬件友好的部分：遍历 splat 覆盖像素、查表计算 Gaussian 权重、执行 alpha blending，并将结果实时输出到显示器。

这样可以在较低工程复杂度下，实现一个真正能跑、能展示、具有 3DGS 特征的 FPGA neural rendering demo。
