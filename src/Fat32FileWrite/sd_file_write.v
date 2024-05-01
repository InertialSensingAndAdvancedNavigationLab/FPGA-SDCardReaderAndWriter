
//--------------------------------------------------------------------------------------------------------
// Module  : sd_file_reader
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: A SD-card host to initialize SD-card and read files
//           Specify a filename, sd_file_reader will read out file content
//           Support CardType   : SDv1.1 , SDv2  or SDHCv2
//           Support FileSystem : FAT16 or FAT32
//--------------------------------------------------------------------------------------------------------
module sd_file_write #(
    parameter [26*8-1:0] SaveFileName     = "SaveData.dat", // file name to read, ignore upper and lower case
    parameter            FileNameLength = 12           , // length of FILE_NAME (in bytes). Since the length of "example.txt" is 11, so here is 11.    
    parameter [2:0] CLK_DIV = 3'd1,  // when clk =   0~ 25MHz , set CLK_DIV = 3'd1,
                                     // when clk =  25~ 50MHz , set CLK_DIV = 3'd2,
                                     // when clk =  50~100MHz , set CLK_DIV = 3'd3,
                                     // when clk = 100~200MHz , set CLK_DIV = 3'd4,

    parameter UART_BPS = 'd921600,     //串口波特率
    parameter CLK_FREQ = 'd20_000_000,  //时钟频率
    /// FIFO位宽
    parameter FIFOSizeWidth=12,
    /// FIFO一次性写入数据，要求为一个扇区512的倍数
    parameter theOnceSaveSize='d512,
    /// 多少数据时更新文件
    parameter updateFileSystemSize='d1
) (
    input  wire       theRealCLokcForDebug,
    // rstn active-low, 1:working, 0:reset
    input  wire       rstn,
    // clock
    input  wire       clk,
    // SDcard signals (connect to SDcard), this design do not use sddat1~sddat3.
    output wire       sdclk,
    inout  wire       sdcmd,
    inout  wire [0:0] sddata,                // FPGA only read SDDAT signal but never drive it
    // the input save data
    input  wire       rx,
    output wire [3:0] ok
);
  /*
ByteAnalyze ReadDebugger(
  .clk(theRealCLokcForDebug),
  .probe0(clk),
  .probe1(inReciveData),
  .probe2(reciveDataAddress),
  .probe3(reciveData),
  .probe4(sddata)*/
  ByteAnalyze writeDebugger (
      .clk(theRealCLokcForDebug),
      .probe0(clk),
      .probe1(havdGetDataToSend),
      .probe2(theSectorAddress),
      .probe3(sendData),
      .probe4(writeSDData),
      .probe5(requireFIFOOutput),
      .probe6(FIFOWriteOutData)
  );
  /// 初始化initialize的状态,以最高位为分界线，当最高位为0时，处于初始化-读状态，当最高位为1时，处于工作-写状态
  reg [3:0] workState;
  /// 其最低位为0：完成,提前准备；1：正在进行；
  localparam [3:0] inReset = 'b0000,
  /// 初始化SD卡驱动
  initializeMBRorDBR = 'b0001,
  /// 初始化SD卡驱动完成
  initializeMBRorDBRFinish = 'b0010,
  /// 初始化读BPR表得到系统数据
  initializeBPR = 'b0011,
  /// 初始化读BPR表得到系统数据完成
  initializeBPRFinish = 'b0110,
  /// 读文件系统信息
  initializeFileSystem = 'b0111,
  /// 读取文件信息完成，同时也意味着SDIO控制权交给写模块
  initializeFileSystemFinish = 'b1000,
  /// 读取文件信息完成，亦为等待数据状态
  waitEnoughData = 'b1000,
  /// 开始写入数据，先写FIFO数据
  WriteFIFOData = 'b1001,
  /// FIFO数据（一个扇区，512字节）写入完成
  writeFIFODataEnd = 'b1010,
  /// 开始写入文件长度修改后的新文件扇区
  updateFileSystem = 'b1011,
  /// 更新文件所在扇区完成
  updateFileSystemFinish = 'b1100, unKonwError = 'b1111;

  /// SDIO总裁模块，决定当前SDIO由读(Output:0)模块控制还是由写模块(Input:1)控制
  wire SDIOReadWrite;
  /// 现更新为由workState最高位决定
  assign SDIOReadWrite = workState[3];
  /// 当写入模块拥有SDIO控制权时，系统处于工作状态
  assign ok = workState;

  localparam [0:0] SDIORead = 1'b0, SDIOWrite = 1'b1;
  wire [32*8-1:0] longFileName, shortFileName;

  /// 文件起始扇区
  reg [31:0] fileSystemSector;
  /// 文件起始扇区
  wire [31:0] fileStartSector;
  /// 
  reg [31:0] fileSectorLength;
  /// SD接收数据线

  /// 串口读入的字节数据
  wire [7:0] rx_data;
  /// 串口完成一个字节读入的标识
  wire rx_flag;
  /// SD接收模块，将接收到的串口信号
  SDUartRX #(
      .UART_BPS(UART_BPS),  //串口波特率
      .CLK_FREQ(CLK_FREQ)   //时钟频率
  ) SDUartInput (
      .sys_clk  (clk),      //20Mhz
      .sys_rst_n(rstn),
      .rx       (rx),
      .po_data  (rx_data),
      .po_flag  (rx_flag)
  );
  wire [7:0] FIFOWriteOutData;
  wire [FIFOSizeWidth-1:0] theNumberOfFIFOData;
  reg requireFIFOOutput, havdGetDataToSend;
  /// FIFO先入先出，将串口数据保存，以及以块写入SD卡
  wr_fifo UartInputData (
      .rst(~rstn),  // input rst
      .wr_clk(clk),  // input wr_clk
      .rd_clk(clk),  // input rd_clk
      .din(rx_data),  // input [7 : 0] din
      .wr_en(rx_flag),  // input wr_en
      // FIFO数据为电平触发而非边沿触发，故需要requireFIFOOutput控制。这FIFO，requireFIFOOutput拉高再拉低居然是2.5个时钟周期，得操作一手上个锁
      // 拉高是立刻拉高，但是拉低操作要下个周期执行（可能是优化操作，使得拉高操作是被原先的拉高命令直接拉高）
      .rd_en(requireFIFOOutput),  // input rd_en
      .dout(FIFOWriteOutData),  // output [7 : 0] dout
      .full(),  // output full
      .empty(),  // output empty
      .rd_data_count(theNumberOfFIFOData)  // output [11 : 0] rd_data_count
  );
  /// MBR信息区，位于0x00扇区，所有扇区均需偏移该地址
  wire [31:0] theBPRDirectory;
  reg MBREdit;
  ReadMBRorDBR theMBRorDBRInformationProvider (
      .theBPRDirectory(theBPRDirectory),
      .isEdit(MBREdit),
      .EditAddress(theReciveDataAddress),
      .EditByte(theReciveData)
  );
  /// BPR信息区，需要先读取MBR信息得到BPR所在扇区。SD卡读卡器所看到的0x00扇区为此扇区，但其在SD卡中地址编号并非0x00。需要额外增加theBPRDirectory得到真实根地址
  wire [31:0] theRootDirectory;
  reg BPREdit;
  ReadBPR theBPRInformationProvider (
      .theRootDirectory(theRootDirectory),
      .isEdit(BPREdit),
      .EditAddress(theReciveDataAddress),
      .EditByte(theReciveData)
  );
  /// 文件扇区信息区
  reg isLoadRam;
  reg [8:0] EditRAMAddress;
  reg [7:0] editRAMByte;
  reg [8:0] theFileInformationBlockByteAddress;
  wire [7:0] theFileInformationBlockByte;
  reg checkoutFileExit;
  wire FileExist;
  wire FileNotExist;
  FileSystemBlock theFileInformationKeeper (
      .theRealCLokcForDebug(theRealCLokcForDebug),
      .Clock(clk),
      .InputOrOutput(isLoadRam),
      .writeAddress(EditRAMAddress),
      .EditByte(editRAMByte),
      .readAddress(theFileInformationBlockByteAddress),
      .Byte(theFileInformationBlockByte),
      .checkoutFileExit(checkoutFileExit),
      .FileExist(FileExist),
      .FileNotExist(FileNotExist),
      .fileStartSector(fileStartSector),
      .theChangeFileInput({longFileName, shortFileName})
  );
/*
  /// 先保存长文件名，若长文件名的长度超过了13个字符(utf16编码，26字节)，则需要额外配置一个CreatelongFileName，并且修改其位置编号参数
  CreatelongFileName LongFileName (
      .verify(fileSectorLength),
      /// FIFO的特性为高位先出，BRAM的特性为低位先出，请使用BRAM缓存该数据，或修改该数据以配置FIFO高位先出
      .theFAT32FileName(longFileName)
  );
  /// 数个长文件名后接的短文件名，为包含文件属性的真实文件配置
  CreateShortFileName ShortFileName (
      .theFileStartSector(fileStartSector),
      .fileSectorLength(fileSectorLength),
      /// FIFO的特性为高位先出，BRAM的特性为低位先出，请使用BRAM缓存该数据，或修改该数据以配置FIFO高位先出
      .theFAT32FileName(shortFileName)
  );*/
  /// SD卡状态
  wire [3:0] SDcardState;
  wire [1:0] SDCardType;
  /// fileSectorLength低10位始终为0，即fileSectorLength为512的整数倍
  //assign fileSectorLength[9:0] = 10'b0000000000;
  /// 系统初始化状态机
  always @(posedge clk or negedge rstn) begin
    /// 系统复位
    if (rstn == 0) begin
      workState <= inReset;
    end  /// 系统初始化
    else begin
      case (workState)
        /// 复位状态，此时需要先准备初始化SDIO
        inReset: begin
          checkoutFileExit <= 0;
          requireFIFOOutput <= 0;
          havdGetDataToSend <= 0;
          sendDataEnable <= 0;
          readStart <= 0;
          /// 工作见reader模块，当获取到了SD卡类型后，设置系统参数，进入等待状态，认为SDIO初始化完成，SDcardState稳定状态位于8，CMD17
          if (readingIsDoing == 0) begin
            /// 初始化完成，接下来进行读取MBR，在此给出一个周期的读使能信号
            workState <= initializeMBRorDBR;
            readStart <= 1;
          end
        end
        initializeMBRorDBR: begin
          /// 如此操作，使得接收数据后，编辑操作推迟一个时钟周期，以确保数据稳定，避免亚稳态
          if (inReciveData) begin
            theReciveData <= reciveData;
            theReciveDataAddress <= reciveDataAddress;
            isReciveData <= 1;
          end else if (isReciveData) begin
            MBREdit <= 1;
            isReciveData <= 0;
          end else begin
            MBREdit <= 0;
          end
          readStart <= 0;
          /// 工作见initializeMBRorDBR模块，当读取结束时进入判定阶段
          if (reciveEnd) begin
            workState <= initializeMBRorDBRFinish;
          end
        end
        /// SDIO初始化完成，准备读取BPR，在此进行一个时钟的数据调整
        initializeMBRorDBRFinish: begin
          /// 检查BPR得到的地址是否合理。理应存在MBR扇区，使得真实BPR扇区不为0
          if (theBPRDirectory > 32'd0 && theBPRDirectory <= 32'h00010000) begin
            workState <= initializeBPR;
            /// Finish阶段也是下一个阶段的准备阶段，准备下个扇区的读地址
            theSectorAddress <= theBPRDirectory;
            /// 读取使能应该是只需要使能一个周期即可，而不是一直使能
            readStart <= 1;
          end 
          /// BPR地址不合理：可以反复搜索0地址，也可以自动往后搜索，重新进行读取BPR阶段
          else begin
            workState <= initializeMBRorDBR;
            theSectorAddress <= 0;  // <= theSectorAddress + 1;
            readStart <= 1;
          end
        end
        /// 读取BPR，事实上由于读程序仅用于初始化，故详见以reciveData和ReciveEnd的电路模块。在那里ReciveEnd时进入下一个状态，因为担心Recive时会错误的覆盖数据（虽然事实上没有数据能覆盖）
        initializeBPR: begin
          if (inReciveData) begin
            theReciveData <= reciveData;
            theReciveDataAddress <= reciveDataAddress;
            isReciveData <= 1;
          end else if (isReciveData) begin
            BPREdit <= 1;
            isReciveData <= 0;
          end else begin
            BPREdit <= 0;
          end
          readStart <= 0;
          if (reciveEnd) begin
            workState <= initializeBPRFinish;
          end
        end
        /// 读取BPR信息完成后，接下来是需要载入记录文件信息的所在块，以此在定期保存状态下将修改后的文件信息保存
        initializeBPRFinish: begin
          /// 检查theRootDirectory是否正确，至少，0号扇区,FAT表,theRootDirectory将大于8(猜的，能算，8肯定有)
          /// 注意，需要检验的有：是否读入扇区成功（估算FAT表，地址不应该超过FAT表，即判断是否为0）（估算扇区范围，避免指向不存在的扇区导致读取文件阶段卡死）
          if ((theRootDirectory > 32'd512) && (theRootDirectory < 32'h00010000)) begin
            /// 此时BPR数据读入，theRootDirectory计算输出文件所在扇区
            theSectorAddress <= theRootDirectory + theBPRDirectory;
            readStart <= 1;
            workState <= initializeFileSystem;
          end
          /// 事实上无论是获得卡状态（未尝试），还是处于等待状态，均并没有初始化完成，以此，当校验不通过时，重新读取BPR信息
          else begin
            readStart <= 1;
            workState <= initializeBPR;
            theSectorAddress <= theBPRDirectory;
          end
        end
        /// 该段见以以reciveData和ReciveEnd的电路模块
        initializeFileSystem: begin

          readStart <= 0;
          /// 特殊：由于加载文件系统完成环节，拥有写权限，事实上进入了下一阶段，故利用判断是否处于检查文件状态插入加载完成检验
          if (checkoutFileExit) begin
            if (FileExist) begin

              workState <= initializeFileSystemFinish;
              checkoutFileExit <= 0;
              fileSystemSector <= theSectorAddress;
              fileSectorLength<=0;
            end else if (FileNotExist) begin
              checkoutFileExit <= 0;
              /// 当前扇区没有符合要求的文件系统，前往下一个扇区寻找
              theSectorAddress <= theSectorAddress + 1;
              readStart <= 1;
              workState <= initializeFileSystem;
            end
          end else begin
            if (inReciveData) begin
              isReciveData <= 1;
              EditRAMAddress <= reciveDataAddress;
              editRAMByte <= reciveData;
            end else if (isReciveData) begin

              isLoadRam <= 1;
              isReciveData <= 0;
            end else if (reciveEnd) begin
              checkoutFileExit <= 1;
              isLoadRam <= 0;
            end
          end
        end
        /// 在读取完文件系统后，读模块将不再使用，接下来仅使用写模块，按照先更新扇区内容，再将更新的扇区内容信息载入文件系统交替执行。
        initializeFileSystemFinish: begin
          /// 转让文件使用权
          //SDIOReadWrite<=SDIOWrite;
          workState <= waitEnoughData;
          if (theNumberOfFIFOData > theOnceSaveSize) begin
            workState <= WriteFIFOData;
            theSectorAddress <= fileStartSector + fileSectorLength;
            sendStart <= 1;
            /// 从FIFO中预读取一个数据
            requireFIFOOutput <= 1;
          end

        end
        WriteFIFOData: begin
          sendStart <= 0;
          if (requireFIFOOutput) begin
            requireFIFOOutput <= 0;
            havdGetDataToSend <= 1;
          end else if (prepareNextData) begin
            /// 发送512个字节，共:进入1，发送512个字节，共513次装载信号，只需要512个装载信号，最后一个字节511不需要处理装载信号。以最后4位为例，当index为0111，即0:7时，autoFileSystemIndex[31:3]=0，产生第一次装载信号，那么最后一次产生装载信号应该是510:7，即只保留产生信号小于512-2部分。
            if ((~havdGetDataToSend) && (autoFileSystemIndex[31:3] < (theOnceSaveSize - 'd1))) begin
              //if (~havdGetDataToSend) begin
              requireFIFOOutput <= 1;
            end
          end else begin
            if (havdGetDataToSend) begin
              /// FIFO数据的赋值，晚于FIFO出来的那一刻。为了保证赋值成功，改为在haveGetDataToSend的下降沿赋值。
              sendData <= FIFOWriteOutData;
            end
            havdGetDataToSend <= 0;
          end
          if (sendFinish) begin
            workState <= writeFIFODataEnd;
            theFileInformationBlockByteAddress <= 0;
          end
        end
        writeFIFODataEnd: begin
          theSectorAddress <= fileSystemSector;
          sendData <= theFileInformationBlockByte;
          havdGetDataToSend <= 1;
          sendStart <= 1;
          fileSectorLength<=fileSectorLength+1;
          workState <= updateFileSystem;
        end
        /// 更新文件系统，工作流程说明：当发送数据至第6位时，调节RAN地址，当发送至第七位时，更新数据，第八位即下一个字节时，自动更新字节
        updateFileSystem: begin
          sendStart <= 0;
          if (prepareNextData && havdGetDataToSend) begin
            theFileInformationBlockByteAddress = theFileInformationBlockByteAddress + 'd1;
            havdGetDataToSend <= 0;
          end else if (~(havdGetDataToSend || prepareNextData)) begin
            havdGetDataToSend <= 1;
            sendData <= theFileInformationBlockByte;
          end
          if (sendFinish) begin
            workState <= updateFileSystemFinish;
          end
        end
        updateFileSystemFinish: begin
          workState <= waitEnoughData;
          havdGetDataToSend <= 0;
        end
        unKonwError: begin

        end
        default: begin
          workState <= inReset;
        end
      endcase

    end
  end
  /*
    /// 因为FIFO这玩意，高电平触发，拉高那个时钟他是真拉高了，拉低那个时钟他还得等下一个时钟才被判定为低。这导致FIFO会触发2次，一次从FIF0中读出了两个数据。故该步骤随时可以执行，只要能让FIFO只触发一个时钟周期即可
    always @(negedge clk ) begin
            if ((~rstn) && requireFIFOOutput) begin
              requireFIFOOutput <= 0;
              sendData <= FIFOWriteOutData;
              havdGetDataToSend <= 1;
            end
    end*/
  /// 开始读
  reg readStart;
  /// 收到的数据
  wire inReciveData;
  /// SDIO读模块部分
  wire [8:0] reciveDataAddress;
  /// SDIO当前读出来的模块
  wire [7:0] reciveData;
  /// SDIO读结束
  wire reciveEnd;
  /// 收到的数据寄存器版
  reg isReciveData;
  /// SDIO读模块部分寄存器版
  reg [8:0] theReciveDataAddress;
  /// SDIO当前读出来的模块寄存器版
  reg [7:0] theReciveData;

  /// 读模块所使用SDIO线，该线需要经过SDIOReadWrite仲裁决定
  wire [0:0] readSDdata;

  wire [15:0] readCMDClockSpeed;
  wire readCMDStart;
  wire [15:0] readCMDPrecnt;
  wire [5:0] readCMDOrderType;
  wire [31:0] readCMDArgument;
  wire readingIsDoing;
  wire [15:0] SDCardRCA;
  sd_reader #(
      .CLK_DIV(CLK_DIV)
  ) readAndInit (
      .rstn     (rstn),
      .clk      (clk),
      .sdclk    (sdclk),
      .sddat0   (readSDdata),
      .card_type(SDCardType),
      .card_stat(SDcardState),
      .rca(SDCardRCA),
      .rstart   (readStart),
      .rsector  (theSectorAddress),
      .rbusy    (readingIsDoing),
      .rdone    (reciveEnd),
      .outen    (inReciveData),
      .outaddr  (reciveDataAddress),
      .outbyte  (reciveData),
      .clkdiv   (readCMDClockSpeed),
      .start    (readCMDStart),
      .precnt   (readCMDPrecnt),
      .cmd      (readCMDOrderType),
      .arg      (readCMDArgument),
      .busy     (busy),
      .done     (done),
      .timeout  (timeout),
      .syntaxe  (syntaxe),
      .resparg  (resparg)
  );
  /// 要读/写的扇区地址
  reg  [31:0] theSectorAddress;
  /// 开始读
  reg         sendStart;
  /// 准备写入的下一个数据，数据已经准备好
  reg         sendDataEnable;
  /// 需要发送的数据
  reg  [ 7:0] sendData;
  /// 成功写入应该字节
  wire        prepareNextData;
  /// 写入结束
  wire        sendFinish;

  /// SDIO
  wire [ 0:0] writeSDData;

  /// SDIO线
  wire [15:0] writeCMDClockSpeed;
  wire        writeCMDStart;
  wire [15:0] writeCMDPrecnt;
  wire [ 5:0] writeCMDOrderType;
  wire [31:0] writeCMDArgument;
  wire [31:0] autoFileSystemIndex;
  sd_write #(
      .CLK_DIV(CLK_DIV)
  ) WriteAndUpdate (
      .theRealCLokcForDebug(theRealCLokcForDebug),
      /// 在交接前，系统始终处于复位状态，监听reader的值作为初始值
      .rstn                (SDIOReadWrite),
      .clk                 (clk),
      .sdclk               (sdclk),
      .sddat0              (writeSDData),
      .writeSectorAddress  (theSectorAddress),
      .StartWrite          (sendStart),
      //.inEnable          (sendDataEnable),
      //.inEnable          (workState == WriteFIFOData ? 'd1 : 'd0),
      .inByte              (sendData),
      //.inbyte            ((workState==WriteFIFOData)?FIFOWriteOutData:'hFF),
      .theWriteBitIndex    (autoFileSystemIndex),
      .prepareNextByte     (prepareNextData),
      .writeBlockFinish    (sendFinish),
      .theCard_type        (SDCardType),
      .theRCA(SDCardRCA),
      .clkdiv              (writeCMDClockSpeed),
      .start               (writeCMDStart),
      .precnt              (writeCMDPrecnt),
      .cmd                 (writeCMDOrderType),
      .arg                 (writeCMDArgument),
      .busy                (busy),
      .done                (done),
      .timeout             (timeout),
      .syntaxe             (syntaxe),
      .resparg             (resparg)
  );
  /// SDCMD线,SDCmd负责向SD卡发送命令，其由读模块和写模块控制。
  /// SDIO Data线由读/写模块控制，其中，读模块仅接收数据，写模块仅发送数据，故当处于读状态时，SDIO处于高阻态读取数据；处于写状态时，SDIO连接写信号
  assign readSDdata = SDIOReadWrite ? 1'bz : sddata[0];
  //assign readSDdata = sddata[0];
  assign sddata[0] = SDIOReadWrite ? writeSDData : 1'bz;
  assign SDCMDClockSpeed = SDIOReadWrite ?writeCMDClockSpeed:readCMDClockSpeed;
  assign    SDCMDStart = SDIOReadWrite ?writeCMDStart:readCMDStart;
  assign    SDCMDPrecnt = SDIOReadWrite ?writeCMDPrecnt: readCMDPrecnt;
  assign    SDCMDOrderType = SDIOReadWrite ?writeCMDOrderType: readCMDOrderType;
  assign    SDCMDArgument= SDIOReadWrite ? writeCMDArgument:readCMDArgument;
  wire [15:0] SDCMDClockSpeed;
  wire        SDCMDStart;
  wire [15:0] SDCMDPrecnt;
  wire [ 5:0] SDCMDOrderType;
  wire [31:0] SDCMDArgument;
  wire        busy;
  wire        done;
  wire        timeout;
  wire        syntaxe;
  wire [31:0] resparg;

  sdcmd_ctrl SDIOCMD (
      .rstn   (rstn),
      .clk    (clk),
      .sdclk  (sdclk),
      .sdcmd  (sdcmd),
      .clkdiv (SDCMDClockSpeed),
      .start  (SDCMDStart),
      .precnt (SDCMDPrecnt),
      .cmd    (SDCMDOrderType),
      .arg    (SDCMDArgument),
      .busy   (busy),
      .done   (done),
      .timeout(timeout),
      .syntaxe(syntaxe),
      .resparg(resparg)
  );
endmodule
