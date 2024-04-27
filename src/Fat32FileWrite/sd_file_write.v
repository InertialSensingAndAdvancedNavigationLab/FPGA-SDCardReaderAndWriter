
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
    parameter FIFOOutputRequire='d512*1,
    /// 多少数据时更新文件
    parameter updateFileSystemSize='d1
) (
    // rstn active-low, 1:working, 0:reset
    input  wire       rstn,
    // clock
    input  wire       clk,
    // SDcard signals (connect to SDcard), this design do not use sddat1~sddat3.
    output wire       sdclk,
    inout  wire           sdcmd,
    input  wire       sddat0,  // FPGA only read SDDAT signal but never drive it
    // the input save data
    input  wire       rx,
    output wire [3:0] ok
);

  /// 初始化initialize的状态,以最高位为分界线，当最高位为0时，处于初始化-读状态，当最高位为1时，处于工作-写状态
  reg [3:0] workState;
  /// 其最低位为0：完成,提前准备；1：正在进行；
  localparam [3:0] inReset = 'b0000,
  /// 初始化SD卡驱动
  initializeSDIO = 'b0001,
  /// 初始化SD卡驱动完成
  initializeSDIOFinish = 'b0010,
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
  updateFileSystemFinish = 'b1100, initializeFinish = 'b1111;

  /// SDIO总裁模块，决定当前SDIO由读(Output:0)模块控制还是由写模块(Input:1)控制
  wire SDIOReadWrite;
  /// 现更新为由workState最高位决定
  assign SDIOReadWrite = workState[3];
  /// 当写入模块拥有SDIO控制权时，系统处于工作状态
  assign ok = workState;
  /// 状态类
  /// 通用扇区，大小为512字节，用于存储一个扇区的数据
  /// 文件系统写入块。当前的设计思路为:简单粗暴的将数据区的第一个文件所处扇区“格式化”，只保留一项文件属性数据
  reg [8:0] FileSaveDataBlock[511:0];
  /// 块地址，用于对块中具体数据操作时，提供操作指向对象:地址自增指针，用于实现每次操作后，指向下一个数据
  wire [9:0] blockAddress;
  /// 地址自增电路使能信号
  reg blockAddressEnable;
  /// 地址自增电路，位宽11，即0-1023，用于包含数据512，可将大于512部分数据作为状态机使用
  Count #(
      .CountWidth(10)
  ) BlockAddressBoost (
      /// 当系统未初始化完成，系统并不会向SD卡中写入数据，故一定始终为0，始终复位
      .sys_rst_n(blockAddressEnable),
      .AddOnce  (wr_req),
      /// 舍弃掉低10位，即相当于FileLength乘以512，那么需要注意的是，实际上计数器只使用了[21:0]，22位，高于22位的技术将溢出舍弃
      .NowCount (blockAddress)
  );

  localparam [0:0] SDIORead = 1'b0, SDIOWrite = 1'b1;
  /// 通用扇区
  /// 
  wire [32*8-1:0] longFileName, shortFileName;
  /// 文件起始扇区
  reg [32:0] fileStartSector;
  /// 
  wire [31:0] fileLength;
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
      .sys_clk  (clk),   //?????20Mhz
      .sys_rst_n(rstn),  //??????
      .rx       (rx),    //???????????

      .po_data(rx_data),  //?????????????????
      .po_flag(rx_flag)   //????????????????????????????
  );
  wire [7:0] FIFOWriteOutData;
  wire [FIFOSizeWidth-1:0] theNumberOfFIFOData;
  /// FIFO先入先出，将串口数据保存，以及以块写入SD卡
  wr_fifo UartInputData (
      .rst(~rstn),  // input rst
      .wr_clk(clk),  // input wr_clk
      .rd_clk(clk),  // input rd_clk
      .din(rx_data),  // input [7 : 0] din
      .wr_en(rx_flag),  // input wr_en
      .rd_en(wr_req),  // input rd_en
      .dout(FIFOWriteOutData),  // output [7 : 0] dout
      .full(),  // output full
      .empty(),  // output empty
      .rd_data_count(theNumberOfFIFOData)  // output [11 : 0] rd_data_count
  );
  /// BPR信息区

  wire [31:0] theRootDirectory;
  ReadBPR theBPRInformationProvider (
      .theRootDirectory(theRootDirectory),
      .isEdit((workState == initializeBPR) && inReciveData),
      .EditAddress(reciveDataAddress),
      .EditByte(reciveData)
  );
  /// 文件扇区信息区
  reg isEditRAM;
  reg [9:0] ramAddress;
  reg [7:0] editRAMByte;
  FileSystemBlock theFileInformationKeeper (
      .InputOrOutput(isEditRAM),
      .ByteAddress(ramAddress),
      .EditByte(editRAMByte),
      .Byte(reciveData)
  );
  //reg  [31:0] theRootDirectoryAddress;
  getTheRootDirectory GetTheFileDirectoryStartAddress (
      /// 保留扇区数
      .ReservedSectors(ReservedSectors),
      /// 每FAT扇区数
      .theLengthOfFAT(theLengthOfFAT),
      /// FAT表一般均为2，在此视为参数。当然，读取也行。
      .NumberOfFAT(NumberOfFAT),
      /// 根路径地址所在扇区,若使用的是非SD卡设备，可以精确到字节，那么请自行乘以theSizeofSectors
      .theRootDirectory(theRootDirectory)
  );
  /// 先保存长文件名，若长文件名的长度超过了13个字符(utf16编码，26字节)，则需要额外配置一个CreatelongFileName，并且修改其位置编号参数
  CreatelongFileName LongFileName (
      .verify(fileLength),
      /// FIFO的特性为高位先出，BRAM的特性为低位先出，请使用BRAM缓存该数据，或修改该数据以配置FIFO高位先出
      .theFAT32FileName(longFileName)
  );
  /// 数个长文件名后接的短文件名，为包含文件属性的真实文件配置
  CreateShortFileName ShortFileName (
      .theFileStartSector(fileStartSector),
      .FileLength(fileLength),
      /// FIFO的特性为高位先出，BRAM的特性为低位先出，请使用BRAM缓存该数据，或修改该数据以配置FIFO高位先出
      .theFAT32FileName(shortFileName)
  );
  /// 数据写入长度计数器，记录的是已写入SD卡的数据，而非串口接收的数据
  Count #(
      .CountWidth(21)
  ) TheWriteDataLength (
      /// 当系统未初始化完成，系统并不会向SD卡中写入数据，故一定始终为0，始终复位
      .sys_rst_n(workState != inReset),
      .AddOnce  (sendFinish),
      /// 舍弃掉低10位，即相当于FileLength乘以512，那么需要注意的是，实际上计数器只使用了[21:0]，22位，高于22位的技术将溢出舍弃
      .NowCount (fileLength[31:10])
  );
  /// SD卡状态
  wire [3:0] SDcardState;
  wire [1:0] SDCardType;
  /// FileLength低10位始终为0，即FileLength为512的整数倍
  assign fileLength[9:0] = 10'b0000000000;
  /// 系统初始化状态机
  always @(posedge clk or negedge rstn) begin
    /// 系统复位
    if (rstn == 0) begin
      workState <= inReset;
      blockAddressEnable <= 0;
    end  /// 系统初始化
    else begin
      case (workState)
        /// 复位状态，此时需要先准备初始化SDIO
        inReset: begin
          workState <= initializeSDIO;
          //SDIOReadWrite<=SDIORead;
        end
        initializeSDIO: begin
          /// 当获取到了SD卡类型时，认为SDIO初始化完成
          /// 此时认为SDcartstate为ACMD41
          //          if (SDCardType > 2'd0) begin
          /// SDcardState稳定状态位于8，CMD17
          if (SDcardState == 4'd8) begin
            workState <= initializeSDIOFinish;
            //SDIOReadWrite<=SDIORead;
          end
        end
        /// SDIO初始化完成，准备读取BPR，在此进行一个时钟的数据调整
        initializeSDIOFinish: begin
          /// 直接进入读BPR状态，本状态只存在于一个时钟周期
          workState <= initializeBPR;
          /// 读取总线交给读模块
          //SDIOReadWrite<=SDIORead;
          /// 读取地址修改为0
          theSectorAddress <= 0;
          /// 读取使能应该是只需要使能一个周期即可，而不是一直使能
          readStart <= 1;
        end
        /// 读取BPR，事实上由于读程序仅用于初始化，故详见以reciveData和ReciveEnd的电路模块。在那里ReciveEnd时进入下一个状态，因为担心Recive时会错误的覆盖数据（虽然事实上没有数据能覆盖）
        initializeBPR: begin
          readStart <= 0;
          if (reciveEnd) begin
            workState <= initializeBPRFinish;
          end
        end
        /// 读取BPR信息完成后，接下来是需要载入记录文件信息的所在块，以此在定期保存状态下将修改后的文件信息保存
        initializeBPRFinish: begin
          /// 检查theRootDirectory是否正确，至少，0号扇区,FAT表,theRootDirectory将大于8(猜的，能算，8肯定有)
          if (theRootDirectory > 'd64) begin
            /// 此时BPR数据读入，theRootDirectory计算输出文件所在扇区
            theSectorAddress <= theRootDirectory;
            readStart <= 1;
            workState <= initializeFileSystem;
          end
        end
        /// 该段见以以reciveData和ReciveEnd的电路模块
        initializeFileSystem: begin
          readStart <= 0;

          isEditRAM <= 0;
          if (inReciveData) begin
            isEditRAM   <= 1;
            ramAddress  <= reciveDataAddress;
            editRAMByte <= reciveData;
          end
          if (reciveEnd) begin
            workState <= initializeFileSystemFinish;
          end

        end
        /// 在读取完文件系统后，读模块将不再使用，接下来仅使用写模块，按照先更新扇区内容，再将更新的扇区内容信息载入文件系统交替执行。
        initializeFileSystemFinish: begin
          /// 转让文件使用权
          //SDIOReadWrite<=SDIOWrite;
          //workState <= initializeFinish;
          if (theNumberOfFIFOData > FIFOOutputRequire) begin
            workState <= WriteFIFOData;
            theSectorAddress <= theRootDirectory + fileLength[31:10];
            blockAddressEnable <= 1;
          end

        end
        WriteFIFOData: begin
          if (sendFinish) begin
            workState <= writeFIFODataEnd;

          end
          //  sendData<=FileSaveDataBlock[blockAddress];
        end
        writeFIFODataEnd: begin

          theSectorAddress   <= theRootDirectory;
          blockAddressEnable <= 1;
          //  sendData<=FileSaveDataBlock[blockAddress];
        end
        updateFileSystem: begin

          if (sendFinish) begin
            workState <= updateFileSystemFinish;

          end
          //  sendData<=FileSaveDataBlock[blockAddress];
        end
        updateFileSystemFinish: begin
          workState <= waitEnoughData;
          //  sendData<=FileSaveDataBlock[blockAddress];
        end

        default: begin
          workState <= inReset;
        end
      endcase

    end  /// 系统工作
    /*
    else begin
      FileSaveDataBlock[0] <= longFileName;
      FileSaveDataBlock[4] <= shortFileName;
    end*/
  end
  /// 开始读
  reg readStart;
  /// 收到的数据
  wire inReciveData;
  /// SDIO读模块部分
  wire [31:0] reciveDataAddress;
  /// SDIO当前读出来的模块
  wire [7:1] reciveData;
  /// SDIO读结束
  wire reciveEnd;

  /// 读模块所使用SDIO线，该线需要经过SDIOReadWrite仲裁决定
  wire [0:0] readSDdata;

  wire [15:0] readCMDClockSpeed;
  wire readCMDStart;
  wire [15:0] readCMDPrecnt;
  wire [5:0] readCMDOrderType;
  wire [31:0] readCMDArgument;
  sd_reader #(
      .CLK_DIV(CLK_DIV)
  ) readAndInit (
      .rstn     (rstn),
      .clk      (clk),
      .sdclk    (sdclk),
      .sddat0   (readSDdata),
      .card_type(SDCardType),
      .card_stat(SDcardState),
      .rstart   (readStart),
      .rsector  (theSectorAddress),
      .rbusy    (),
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
  /*
  /// 读BPR代码，工作条件：reciveData
  always @(inReciveData or reciveEnd) begin
    if (rstn && reciveEnd == 0 && SDIOReadWrite == SDIORead) begin
      /// 读BPR代码仅在初始化状态为读取BPR状态，即SDIO初始化完成状态使用。
      if (workState == initializeBPR) begin
        case (reciveDataAddress)
          /// 0x0E，保留扇区数,占用2字节。小端模式，高位在高，低位在地
          'hE: begin
            ReservedSectors[7:0] <= reciveData;
          end
          'hF: begin
            ReservedSectors[15:8] <= reciveData;
          end
          /// 0x10,FAT表的份数
          'h10: begin
            NumberOfFAT <= reciveData;
          end
          /// 0x24:每FAT扇区数，占用4个字节
          'h24: begin
            theLengthOfFAT[7:0] <= reciveData;
          end
          'h25: begin
            theLengthOfFAT[15:8] <= reciveData;
          end
          'h26: begin
            theLengthOfFAT[23:16] <= reciveData;
          end
          'h27: begin
            theLengthOfFAT[31:24] <= reciveData;
          end
        endcase
      end else if (workState == initializeFileSystem) begin
        FileSaveDataBlock[reciveDataAddress] <= reciveData;
      end
    end
  end

*/
  /// 要读/写的扇区地址
  reg  [31:0] theSectorAddress;
  /// 开始读
  reg         sendStart;
  /// 准备写入的下一个数据，数据已经准备好
  reg         sendDataEnable;
  /// 需要发送的数据
  reg  [ 7:0] sendData;
  /// 成功写入应该字节
  wire        sendEnd;
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
  sd_write #(
      .CLK_DIV(CLK_DIV)
  ) WriteAndUpdate (
      .rstn              (rstn),
      .clk               (clk),
      .sdclk             (sdclk),
      .sddat0            (writeSDData),
      .writeSectorAddress(theSectorAddress),
      .StartWrite        (sendStart),
      .inEnable          (sendDataEnable),
      .inbyte            (sendData),
      .writeByteSuccess  (sendEnd),
      .writeBlockFinish  (sendFinish),
      .clkdiv            (writeCMDClockSpeed),
      .start             (writeCMDPrecnt),
      .precnt            (writeCMDStart),
      .cmd               (writeCMDOrderType),
      .arg               (writeCMDArgument),
      .busy              (busy),
      .done              (done),
      .timeout           (timeout),
      .syntaxe           (syntaxe),
      .resparg           (resparg)
  );
  /*
  /// 写数据代码，这个没办法，只能时钟驱动
  always @(posedge clk) begin
    if (rstn && sendEnd==0&&SDIOReadWrite==SDIOWrite) begin
      /// 读BPR代码仅在初始化状态为读取BPR状态，即SDIO初始化完成状态使用。
      if (workState == initializeBPR) begin
          case (reciveDataAddress)
            /// 0x0E，保留扇区数,占用2字节。小端模式，高位在高，低位在地
            'hE: begin
              ReservedSectors[7:0] <= reciveData;
            end
            'hF: begin
              ReservedSectors[15:8] <= reciveData;
            end
            /// 0x10,FAT表的份数
            'h10: begin
              NumberOfFAT <= reciveData;
            end
            /// 0x24:每FAT扇区数，占用4个字节
            'h24: begin
              theLengthOfFAT[7:0] <= reciveData;
            end
            'h25: begin
              theLengthOfFAT[15:8] <= reciveData;
            end
            'h26: begin
              theLengthOfFAT[23:16] <= reciveData;
            end
            'h27: begin
              theLengthOfFAT[31:24] <= reciveData;
            end
          endcase
      end
      else if (workState == initializeFileSystem) begin
          FileSaveDataBlock[reciveDataAddress] <= reciveData;
      end
    end
  end*/
  /// SDIO总线总裁
  always @(*) begin
    //sendData <= FileSaveDataBlock[blockAddress];
    /*
    if (SDIOReadWrite == SDIORead) begin
      SDCMDClockSpeed <= readCMDClockSpeed;
      SDCMDStart <= readCMDStart;
      SDCMDPrecnt <= readCMDPrecnt;
      SDCMDOrderType <= readCMDOrderType;
      SDCMDArgument <= readCMDArgument;
    end 
    else begin
      SDCMDClockSpeed <= writeCMDClockSpeed;
      SDCMDStart <= writeCMDStart;
      SDCMDPrecnt <= writeCMDPrecnt;
      SDCMDOrderType <= writeCMDOrderType;
      SDCMDArgument <= writeCMDArgument;
    end*/
  end
  /// SDCMD线,SDCmd负责向SD卡发送命令，其由读模块和写模块控制。
  /// SDIO Data线由读/写模块控制，其中，读模块仅接收数据，写模块仅发送数据，故当处于读状态时，SDIO处于高阻态读取数据；处于写状态时，SDIO连接写信号
  assign readSDdata = sddat0;//SDIOReadWrite ? 1'bz : sddat0;
  //assign sddat0 = SDIOReadWrite ? writeSDData : 1'bz;
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
