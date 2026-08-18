# MATLAB Golden Model 与 Verilog Sobel 仿真闭环

这个项目完成第一阶段学习目标：

```text
MATLAB 整数 Golden Model
          ↓
十六进制图像像素文件
          ↓
Verilog Testbench → 两行缓存 → 3×3 Sobel RTL
          ↓
RTL 输出像素文件
          ↓
Python 逐像素比较、误差图和 PASS/FAIL 报告
```

第一阶段只做 Vivado XSIM 仿真，不依赖 Red Pitaya、AXI4-Stream、ILA、JTAG 下载器或摄像头接口。

## 1. 已冻结的算法定义

- 输入：8-bit 灰度图，按行从左到右、从上到下输入。
- 窗口：标准 3×3 Sobel。
- 水平梯度：右列加权和减去左列加权和。
- 垂直梯度：下行加权和减去上行加权和。
- 幅值：`abs(Gx) + abs(Gy)`，不计算平方根。
- 饱和：大于 255 时输出 255。
- 边界：最外圈像素固定输出 0。
- MATLAB 整数实现是唯一 Golden Model；Python 不重新定义 Sobel 算法。

## 2. 项目结构

```text
sobel_rtl_golden/
├─ rtl/
│  ├─ sobel_operator.v       # 纯组合 3×3 Sobel 与 8-bit 饱和
│  └─ sobel_stream_core.v    # 两行缓存、滑动窗口、流时序和边界刷新
├─ tb/
│  └─ tb_sobel_image.v       # 图像像素输入、RTL 输出文件和数量检查
├─ matlab/
│  └─ generate_golden.m      # 生成测试图、输入 mem 和 Golden mem
├─ python/
│  └─ compare_results.py     # 逐像素比较、CSV/JSON 报告和 PGM 误差图
├─ scripts/
│  └─ run_all.ps1            # 一键运行完整闭环
├─ testdata/                 # 运行后生成输入、Golden 与 RTL 数据
├─ reports/                  # 运行后生成比较报告和重建图像
└─ build/xsim/               # Vivado 编译、仿真日志与 WDB 波形
```

## 3. 一键运行

在 PowerShell 中进入克隆后的项目目录：

```powershell
Set-Location '<your-path>\fpga-sobel-rtl-golden'
& '.\scripts\run_all.ps1'
```

如果Vivado、MATLAB或Python没有加入系统`PATH`，可以显式传入路径：

```powershell
& '.\scripts\run_all.ps1' `
    -VivadoBin '<Vivado-2020.1-bin>' `
    -MatlabExe '<matlab.exe>' `
    -PythonExe '<python.exe>'
```

脚本不会修改系统 `PATH`。MATLAB 的临时偏好目录通过当前进程的
`MATLAB_PREFDIR` 放到 `build/matlab_pref/`，并使用 `-nojvm` 批处理模式；
脚本结束后会恢复原来的环境变量，不修改用户的永久配置。

可选的 Red Pitaya Z10 可综合性检查：

```powershell
& '.\scripts\run_synth_check.ps1' -VivadoBat '<Vivado-2020.1-bin>\vivado.bat'
```

该命令只进行面向 `xc7z010clg400-1` 的核级综合检查，不生成上板位流，也不修改现有 Red Pitaya 工程。

完整流程依次执行：

1. MATLAB 生成六组确定性 64×64 测试数据。
2. `xvlog` 编译纯 Verilog RTL 与 Testbench。
3. `xelab` 建立 XSIM 仿真快照。
4. `xsim` 分别运行六组图像。
5. Python 检查每个像素、输出长度和边界值。

测试集包括常量图、垂直台阶、水平台阶、单像素冲激、结构化图案和固定种子随机图。

## 4. 怎样判断验证通过

终端最终应显示每组：

```text
status = PASS
mismatches = 0
max_error = 0
border_nonzero = 0
```

重点输出：

- `reports/comparison_report.csv`：适合表格检查。
- `reports/comparison_report.json`：适合自动化处理。
- `reports/previews/*_rtl.png`：RTL 重建图像。
- `reports/previews/*_absdiff.png`：绝对误差图；全黑表示逐像素完全一致。
- `build/xsim/logs/*.log`：每个 Testbench 日志。
- `build/xsim/waves/*.wdb`：可在 Vivado 仿真界面查看的波形。
- `reports/synthesis_console_xc7z010.log`：面向 Zynq-7010 的完整综合控制台记录。
- `reports/synthesis_status_xc7z010.txt`：综合是否通过及工具退出状态。
- `reports/synthesis_utilization_xc7z010.rpt`：Vivado 正常完成清理时生成的综合资源报告。
- `reports/synthesis_timing_xc7z010_100mhz.rpt`：Vivado 正常完成清理时生成的核级综合时序报告；它不是完整 Red Pitaya 工程的布局布线时序结论。

## 5. 推荐学习顺序

### 第一步：只看卷积算术

先阅读 `rtl/sobel_operator.v`，对照简单项目：

- [tharunchitipolu/sobel-edge-detector](https://github.com/tharunchitipolu/sobel-edge-detector)

重点理解权重 `1, 2, 1` 如何用移位实现，以及为什么 Gx/Gy 需要有符号扩展。

### 第二步：学习两行缓存与滑动窗口

再阅读 `rtl/sobel_stream_core.v`，对照：

- [erendn/sobel-pipeline-fpga](https://github.com/erendn/sobel-pipeline-fpga)

重点跟踪 `input_row/input_col`、两行缓存和六个水平移位寄存器怎样共同组成 3×3 窗口。

### 第三步：学习图像 Testbench

阅读 `tb/tb_sobel_image.v`，理解：

- `$readmemh` 怎样加载图像；
- 为什么 `frame_start` 比第一像素提前一个时钟；
- 为什么 RTL 在末尾还要刷新 `IMAGE_WIDTH+1` 个边界输出；
- 怎样检查输出像素总数等于输入像素总数。

### 第四步：学习 Golden Model 验证

阅读 MATLAB 与 Python 脚本，并参考包含 Python 比较结构的中文工程：

- [YenLaurent/image-process-on-fpga](https://github.com/YenLaurent/image-process-on-fpga)

不要直接用 MATLAB `edge`、`imfilter` 或 OpenCV `Sobel` 代替当前 Golden Model，因为默认边界、输出深度和饱和规则可能不同。

### 第五步：以后再看真实板级输入输出

第一阶段验证完成后，再参考：

- [AngeloJacobo/FPGA_RealTime_and_Static_Sobel_Edge_Detection](https://github.com/AngeloJacobo/FPGA_RealTime_and_Static_Sobel_Edge_Detection)

该项目包含 MATLAB 图像提取、Python 串口、SDRAM、VGA 与摄像头，适合后续学习，不适合第一阶段直接照搬。

## 6. 与 Red Pitaya 的边界

当前 `sobel_stream_core` 不是 AXI IP，但可以被以后新增的 `redpitaya_wrapper` 包装：

- 小图功能测试：PS → AXI Memory-Mapped BRAM/FIFO → Sobel → BRAM/FIFO → PS。
- 连续高速图像：DMA/AXI4-Stream → Sobel → DMA/AXI4-Stream。
- 没有 JTAG 下载器时：第一阶段完全依靠 XSIM；以后上板可由 PS/Linux 写入测试数据并读回结果。

不建议让 PS 通过 AXI-Lite 寄存器逐像素传输大图，它适合控制寄存器和小规模调试，不适合高吞吐图像流。

## 7. 本机已验证结果（2026-08-18）

- MATLAB R2022a 成功生成六组 64×64 Golden 数据。
- Vivado 2020.1 `xvlog/xelab/xsim` 全部执行成功。
- 六组 Testbench 均输出准确的 4096 个像素。
- 共比较 24,576 个 RTL 输出像素：失配数 0，最大绝对误差 0。
- 六幅 RTL 输出图的外边界非零像素数均为 0。
- 面向 `xc7z010clg400-1` 的核级综合完成，设计报告为 0 error、0 warning；两个 64×8 行缓存均被识别为分布式 RAM。

当前受管 Windows 环境中的 Vivado 2020.1 在综合完成后清理一个已经不存在的临时目录时会给出工具退出警告，`run_synth_check.ps1` 只在日志同时满足“设计综合 0 error/0 warning”和特定 `realtime/tmp` 清理错误时将其标记为工具清理告警；其他综合错误仍会返回失败。该综合检查不是完整 Red Pitaya 工程的布局布线或时序收敛证明。
