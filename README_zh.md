# FPGA SD卡 FAT32 读写器

[![许可证: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

[English](./README_en.md) | [简体中文](./README_zh.md)

## 1. 项目概述

本项目实现了一个基于FPGA的SD卡读写器，支持FAT32文件系统。该系统旨在通过UART接口接收数据，将其缓冲，并写入SD卡上的指定文件中。从SD卡初始化到文件系统管理的整个过程均由Verilog模块处理。

本项目的主要目标是将传感器等数据流以结构化的FAT32格式连续保存到SD卡的文件中。

## 2. 如何开始

请遵循以下简单步骤，在本地运行该项目。

### 环境要求

*   Verilog综合工具（例如 Xilinx ISE 或 Vivado）
*   带有SD卡插槽的FPGA开发板

### 安装步骤

1.  克隆仓库
    ```sh
    git clone https://github.com/InertialSensingAndAdvancedNavigationLab/FPGA-SDCardReaderAndWriter.git
    ```
2.  在您的Verilog开发环境中打开项目。
3.  综合设计并对您的FPGA进行编程。

## 3. 如何使用 (模块实例化)

顶层模块 `sd_file_write` 被设计为可以轻松集成到您自己的项目中。您可以如下实例化它：

```verilog
sd_file_write #(
    .SaveFileName("MyData.dat"),      // SD卡上期望的文件名
    .FileNameLength(10),              // 文件名长度
    .UART_BPS(921600),                // UART 波特率
    .CLK_FREQ(50_000_000)             // 系统时钟频率
) sd_card_writer_inst (
    .theRealCLokcForDebug(your_debug_clock),
    .rstn(your_reset_signal_n),      // 低电平有效复位
    .clk(your_system_clock),        // 系统时钟
    .sdclk(sd_clk_pin),             // SD卡时钟引脚
    .sdcmd(sd_cmd_pin),             // SD卡命令引脚
    .sddata(sd_data_pin),           // SD卡数据引脚 (inout)
    .rx(uart_rx_pin),               // UART 接收引脚
    .ok(status_led)                 // 状态指示灯
);
```

只需将 `clk`、`rstn` 和 `rx` 端口连接到您系统的时钟、复位和UART数据输入。该模块将处理其余部分。

## 4. 系统架构

该系统围绕一个中央控制模块（`sd_file_write`）进行设计，该模块负责协调多个专用子模块的功能。其架构可分为以下几个部分：

*   **UART接口**：`SDUartRX` 模块接收串行数据并将其转换为并行字节。
*   **数据缓冲**：使用FIFO缓冲区（`wr_fifo`）存储输入的数据流，从而能够以完整的512字节扇区为单位将数据写入SD卡。
*   **SD卡控制器**：这是系统的核心，负责与SD卡的所有交互。
*   **FAT32文件系统逻辑**：一组负责解析和操作FAT32文件系统结构的模块。

## 5. 模块说明

| 模块                  | 描述                                                                                                                                     |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `sd_file_write.v`     | 顶层模块，集成所有其他模块并控制整个系统流程。                                                                                             |
| `sd_reader.v`         | 负责SD卡初始化（CMD0, CMD8, CMD55, ACMD41等）和读取512字节扇区（CMD17）。                                                                    |
| `sd_writer.v`         | 负责向SD卡写入512字节扇区（CMD24）并处理相关的数据CRC。                                                                                    |
| `sdcmd_ctrl.v`        | 直接与SD卡的命令线（`sdcmd`）接口的基础模块。                                                                                             |
| `SDUartRX.v`          | 用于数据输入的标准UART接收器。                                                                                                             |
| `FileDefine.v`        | 包含用于创建FAT32文件条目的辅助模块，包括 `CreatelongFileName` 和 `CreateShortFileName`。                                                      |
| `FileAction.v`        | 包含用于解析MBR和BPB等FAT32结构的模块（`ReadMBRorDBR`, `ReadBPR`），以及用于在内存中管理文件系统块的模块（`FileSystemBlock`）。                |
| `FatUpdater.v`        | 包含用于更新文件分配表（FAT）的模块（`FATListBlock`, `UpdateFatStartAddress`）。                                                           |

## 6. 系统流程

系统以状态驱动的方式运行，依次进行初始化、数据收集和写入周期。

<details>
<summary><b>详细初始化流程 (点击展开)</b></summary>

初始化过程由 `sd_file_write.v` 中的 `workState` 状态机管理。以下是详细的步骤分解：

1.  **`inReset`**: 系统在复位后进入此状态。它等待 `sd_reader` 模块完成基本的SD卡初始化。一旦 `sd_reader` 空闲 (`readingIsDoing == 0`)，状态机就转换到下一个状态。
2.  **`initializeMBRorDBR`**: 系统读取SD卡的0号扇区以寻找主引导记录（MBR）。MBR包含分区表，从中可以提取第一个分区的引导记录（DBR或BPB）的位置。DBR/BPB的地址存储在 `theBPRDirectory` 中。
3.  **`initializeMBRorDBRFinish`**: 一个过渡状态，用于验证从MBR读取的地址。如果地址有效，它通过将 `theSectorAddress` 设置为 `theBPRDirectory` 来准备读取DBR。
4.  **`initializeBPR`**: 系统读取DBR/BPB扇区。该扇区包含关于FAT32文件系统的关键信息，例如保留扇区的数量、FAT表的数量以及每簇的扇区数。此信息用于计算根目录的起始地址。
5.  **`initializeBPRFinish`**: 一个过渡状态，用于验证从DBR读取的信息。如果根目录地址看起来有效，它就准备读取根目录以查找目标文件。
6.  **`initializeFileSystem`**: 系统逐个扇区地读取根目录，搜索由 `SaveFileName` 参数指定的文件。它将目录条目中的文件名与目标文件名进行比较。
7.  **`initializeFileSystemFinish` / `waitEnoughData`**: 找到目标文件后，其起始簇和其他信息将被保存。然后系统转换到 `waitEnoughData` 状态，在此状态下，它等待输入FIFO累积足够的数据（512字节）以开始写入过程。此时，SDIO线的控制权被移交给 `sd_writer` 模块。

</details>

### 数据处理与写入阶段

1.  同时，`SDUartRX` 模块监听输入的串行数据并将其存入FIFO。
2.  当FIFO累积足够的数据以填满一个完整的扇区（512字节）时，`sd_file_write` 模块启动写操作。
3.  计算文件的下一个可用扇区地址，并将控制权交给 `sd_writer` 模块。
4.  `sd_writer` 模块将FIFO中的512字节数据块写入SD卡上计算出的扇区。

### 文件系统更新阶段

1.  在写入一定数量的扇区后，系统会更新FAT32文件系统。
2.  更新文件的目录条目，以反映新的、更大的文件大小。
3.  同时更新文件分配表（FAT），将新写入的簇链接到文件中，以确保文件系统的完整性。

### 循环

系统随后返回数据处理状态，不断从UART收集数据，并重复写入和更新的周期。

## 7. 已知问题与限制

此实现是为特定的开发板设计的，可能存在一些错误或限制：

*   **扇区填充不完整**：如果数据传输停止，系统可能会用最后接收到的字节填充最后一个512字节扇区的剩余部分。
*   **波特率敏感**：不正确的UART波特率可能导致数据损坏（例如，写入全零）。
*   **不支持热插拔**：在操作过程中，不能安全地移除和重新插入SD卡。这样做很可能会导致系统挂起。
*   **目标平台上的FIFO行为**：怀疑FIFO模块在目标硬件上可能行为不正常，这可能是由于综合优化引起的。

## 8. 贡献

本项目最初于2023年开发。当时我们在源代码中包含了大量注释，但从未创建过正式的 `README.md` 文件。在2025年，我们使用AI读取代码并生成了这份全面的文档。这凸显了一种全新的、强大的工作方式：过去繁琐的任务现在可以由AI加速完成。

尽管该系统存在缺陷，并且是为特定电路板量身定制的，但我们相信它是一个坚实的基础。借助现代AI工具，我们认为社区可以帮助我们修复剩余的错误并添加新功能，为FPGA社区创建一个可靠的开源文件I/O模块，并显著降低每个人的调试成本。

我们可能不会积极维护此项目，但我们强烈鼓励您使用AI来改进它。如果您在AI的帮助下成功修复了错误或添加了功能，我们非常欢迎您将其贡献回来。

### 如何贡献

1.  Fork 本项目。
2.  创建您的功能分支 (`git checkout -b feature/AmazingFeature`)。
3.  提交您的更改 (`git commit -m 'Add some AmazingFeature'`)。现代AI工具甚至可以帮助您编写清晰、规范的提交信息！
4.  推送到分支 (`git push origin feature/AmazingFeature`)。
5.  开启一个 Pull Request。

### 改进建议

这里有一些想法可以帮助您开始：

*   **关注状态机**：核心逻辑位于 `sd_file_write.v` 中的 `workState` 状态机。理解和修改此状态机是改变系统行为的关键。
*   **仿真是关键**：由于错误的硬件特定性，任何更改都应在部署前在仿真环境中进行彻底测试。
*   **解决已知错误**：“已知问题”部分是一个很好的起点。例如，尝试修复扇区填充不完整的问题，或添加超时机制来处理SD卡的移除。

## 9. 许可证

根据MIT许可证分发。更多信息请参见 `LICENSE` 文件。