# FPGA SD Card FAT32 Reader/Writer

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

[English](./README_en.md) | [简体中文](./README_zh.md)

## 1. Project Overview

This project implements an FPGA-based SD card reader and writer with FAT32 file system support. The system is designed to receive data via a UART interface, buffer it, and write it to a specified file on an SD card. The entire process, from SD card initialization to file system management, is handled by the Verilog modules.

The primary goal of this project is to continuously save data streams (e.g., from sensors) to a file on an SD card in a structured FAT32 format.

## 2. Getting Started

To get a local copy up and running, follow these simple steps.

### Prerequisites

*   A Verilog synthesis tool (e.g., Xilinx ISE or Vivado)
*   An FPGA development board with an SD card slot

### Installation

1.  Clone the repo
    ```sh
    git clone https://github.com/InertialSensingAndAdvancedNavigationLab/FPGA-SDCardReaderAndWriter.git
    ```
2.  Open the project in your Verilog development environment.
3.  Synthesize the design and program your FPGA.

## 3. How to Use (Instantiation)

The top-level module `sd_file_write` is designed to be easily integrated into your own projects. You can instantiate it as follows:

```verilog
sd_file_write #(
    .SaveFileName("MyData.dat"),      // Desired file name on the SD card
    .FileNameLength(10),              // Length of the file name
    .UART_BPS(921600),                // UART baud rate
    .CLK_FREQ(50_000_000)             // System clock frequency
) sd_card_writer_inst (
    .theRealCLokcForDebug(your_debug_clock),
    .rstn(your_reset_signal_n),      // Active-low reset
    .clk(your_system_clock),        // System clock
    .sdclk(sd_clk_pin),             // SD card clock pin
    .sdcmd(sd_cmd_pin),             // SD card command pin
    .sddata(sd_data_pin),           // SD card data pin (inout)
    .rx(uart_rx_pin),               // UART receive pin
    .ok(status_led)                 // Status indicator
);
```

Simply connect the `clk`, `rstn`, and `rx` ports to your system's clock, reset, and UART data input. The module will handle the rest.

## 4. System Architecture

The system is designed around a central control module (`sd_file_write`) that orchestrates the functionality of several specialized sub-modules. The architecture can be broken down as follows:

*   **UART Interface**: The `SDUartRX` module receives serial data and converts it into parallel bytes.
*   **Data Buffering**: A FIFO buffer (`wr_fifo`) is used to store the incoming data stream, allowing for data to be written to the SD card in complete 512-byte sectors.
*   **SD Card Controller**: This is the core of the system, responsible for all interactions with the SD card.
*   **FAT32 File System Logic**: A collection of modules responsible for interpreting and manipulating the FAT32 file system structure.

## 5. Module Descriptions

| Module                | Description                                                                                                                                      |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `sd_file_write.v`     | The top-level module that integrates all other modules and controls the overall system flow.                                                     |
| `sd_reader.v`         | Responsible for SD card initialization (CMD0, CMD8, CMD55, ACMD41, etc.) and reading 512-byte sectors (CMD17).                                     |
| `sd_writer.v`         | Responsible for writing 512-byte sectors to the SD card (CMD24) and handling the associated data CRC.                                            |
| `sdcmd_ctrl.v`        | A fundamental module that directly interfaces with the SD card's command line (`sdcmd`).                                                          |
| `SDUartRX.v`          | A standard UART receiver for data input.                                                                                                         |
| `FileDefine.v`        | Contains helper modules for creating FAT32 file entries, including `CreatelongFileName` and `CreateShortFileName`.                                 |
| `FileAction.v`        | Contains modules for parsing FAT32 structures like the MBR and BPB (`ReadMBRorDBR`, `ReadBPR`) and for managing file system blocks in memory (`FileSystemBlock`). |
| `FatUpdater.v`        | Contains modules for updating the File Allocation Table (`FATListBlock`, `UpdateFatStartAddress`).                                               |

## 6. System Flow

The system operates in a state-driven manner, progressing through initialization, data collection, and writing cycles.

<details>
<summary><b>Detailed Initialization Flow (Click to expand)</b></summary>

The initialization process is managed by the `workState` state machine in `sd_file_write.v`. Here is a step-by-step breakdown:

1.  **`inReset`**: The system starts in this state upon reset. It waits for the `sd_reader` module to complete the basic SD card initialization. Once the `sd_reader` is idle (`readingIsDoing == 0`), the state machine transitions to the next state.
2.  **`initializeMBRorDBR`**: The system reads sector 0 of the SD card to find the Master Boot Record (MBR). The MBR contains the partition table, and from this, the location of the first partition's boot record (the DBR or BPB) is extracted. The address of the DBR/BPB is stored in `theBPRDirectory`.
3.  **`initializeMBRorDBRFinish`**: A transitional state to verify the address read from the MBR. If the address is valid, it prepares to read the DBR by setting `theSectorAddress` to `theBPRDirectory`.
4.  **`initializeBPR`**: The system reads the DBR/BPB sector. This sector contains crucial information about the FAT32 file system, such as the number of reserved sectors, the number of FATs, and the sectors per cluster. This information is used to calculate the starting address of the root directory.
5.  **`initializeBPRFinish`**: A transitional state to verify the information read from the DBR. If the root directory address seems valid, it prepares to read the root directory to find the target file.
6.  **`initializeFileSystem`**: The system reads the root directory, sector by sector, searching for the file specified by the `SaveFileName` parameter. It compares the file names in the directory entries with the target file name.
7.  **`initializeFileSystemFinish` / `waitEnoughData`**: Once the target file is found, its starting cluster and other information are saved. The system then transitions to the `waitEnoughData` state, where it waits for the input FIFO to accumulate enough data (512 bytes) to start the writing process. At this point, the control of the SDIO lines is handed over to the `sd_writer` module.

</details>

### Data Processing and Writing Phase

1.  Concurrently, the `SDUartRX` module listens for incoming serial data and stores it in the FIFO.
2.  When the FIFO accumulates enough data for a full sector (512 bytes), the `sd_file_write` module initiates a write operation.
3.  It calculates the next available sector address for the file and hands over control to the `sd_writer` module.
4.  The `sd_writer` module writes the 512-byte data block from the FIFO to the calculated sector on the SD card.

### File System Update Phase

1.  After a certain number of sectors have been written, the system updates the FAT32 file system.
2.  It updates the file's directory entry to reflect the new, larger file size.
3.  It also updates the File Allocation Table (FAT) to chain the newly written clusters to the file, ensuring file system integrity.

### Loop

The system then returns to its data processing state, continuously collecting data from the UART and repeating the write and update cycle.

## 7. Known Issues and Limitations

This implementation was designed for a specific development board and may have some bugs or limitations:

*   **Incomplete Sector Filling**: If data transmission stops, the system might fill the remainder of the last 512-byte sector with the last received byte.
*   **Baud Rate Sensitivity**: Incorrect UART baud rates can lead to data corruption (e.g., writing all zeros).
*   **No Hot-Swapping**: The SD card cannot be safely removed and re-inserted during operation. Doing so will likely cause the system to hang.
*   **FIFO Behavior on Target Platform**: There is a suspicion that the FIFO module might be behaving incorrectly on the target hardware, possibly due to synthesis optimizations.

## 8. Contributing

This project was originally developed in 2023. While we included extensive comments in the source code, we never created a formal `README.md` file. In 2025, we used an AI to read the code and generate this comprehensive documentation. This highlights a new, powerful way of working: tasks that were once tedious can now be accelerated by AI.

While the system has its flaws and was tailored for a specific board, we believe it's a solid foundation. With modern AI tools, we think the community can help us fix the remaining bugs and add new features, creating a reliable, open-source file I/O module for the FPGA community and significantly reducing debugging costs for everyone.

We may not be actively maintaining this project, but we strongly encourage you to use AI to improve it. If you, with the help of an AI, manage to fix a bug or add a feature, we would be delighted if you would contribute it back.

### How to Contribute

1.  Fork the Project.
2.  Create your Feature Branch (`git checkout -b feature/AmazingFeature`).
3.  Commit your Changes (`git commit -m 'Add some AmazingFeature'`). Modern AI tools can even help you write clean, conventional commit messages!
4.  Push to the Branch (`git push origin feature/AmazingFeature`).
5.  Open a Pull Request.

### Suggested Improvements

Here are a few ideas to get you started:

*   **Focus on the State Machine**: The core logic is in the `workState` state machine within `sd_file_write.v`. Understanding and modifying this state machine is key to changing the system's behavior.
*   **Simulation is Key**: Due to the hardware-specific nature of the bugs, any changes should be thoroughly tested in a simulation environment before deployment.
*   **Address the Bugs**: The "Known Issues" section is a great starting point. For example, try to fix the incomplete sector filling issue or add a timeout mechanism to handle SD card removal.

## 9. License

Distributed under the MIT License. See `LICENSE` for more information.