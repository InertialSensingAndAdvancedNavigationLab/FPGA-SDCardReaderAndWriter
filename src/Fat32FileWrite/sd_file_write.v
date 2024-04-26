
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
    /// 多少数据时更新文件
    parameter updateFileSystemSize='d1
) (
    // rstn active-low, 1:working, 0:reset
    input  wire rstn,
    // clock
    input  wire clk,
    // SDcard signals (connect to SDcard), this design do not use sddat1~sddat3.
    output wire sdclk,
    inout       sdcmd,
    inout  wire sddat0,  // FPGA only read SDDAT signal but never drive it
    // the input save data
    input  wire rx,
    output wire[3:0] ok
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
  initializeBPRFinish = 'b0110, initializeFileSystem = 'b0111,
  /// 读取文件信息完成，同时也意味着SDIO控制权交给写模块
  initializeFileSystemFinish = 'b1000,
  /// 初始化彻底完成
  waitEnoughData = 'b1010,  /*
  startWriteData='b1111;
  writeFIFOData='b1111;
  writeFIFODataFinish='b1111;*/
  updateFileSystem = 'b1110, initializeFinish = 'b1111;

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
  /*
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
  );*/
  /// BPR信息区
  /// 保留扇区数，位于BPB(BIOS Parameter Block)中。该项数据建议从0号扇区中读取，以获得更加兼容性。
  reg  [15:0] ReservedSectors;
  /// 每FAT扇区数
  reg  [31:0] theLengthOfFAT;
  /// FAT表一般均为2
  reg  [ 8:0] NumberOfFAT;
  /// 根路径地址所在扇区,若使用的是非SD卡设备，可以精确到字节，那么请自行乘以theSizeofSectors
  wire [31:0] theRootDirectory;
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
      .sys_rst_n(initializeFinish),
      .AddOnce  (wr_req),
      /// 舍弃掉低10位，即相当于FileLength乘以512，那么需要注意的是，实际上计数器只使用了[21:0]，22位，高于22位的技术将溢出舍弃
      .NowCount (fileLength[31:10])
  );
  /// SD卡状态
  wire [3:0] SDcardState;
  wire [1:0]SDCardType;
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
          readSectorAddress <= 0;
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
          /// 此时BPR数据读入，theRootDirectory计算输出文件所在扇区
          readSectorAddress <= theRootDirectory;
          readStart <= 1;
          workState <= initializeFileSystem;
        end
        /// 该段见以以reciveData和ReciveEnd的电路模块
        initializeFileSystem: begin
          readStart <= 0;
          if (reciveEnd) begin
            workState <= initializeFileSystemFinish;
          end

        end
        /// 在读取完文件系统后，读模块将不再使用，接下来仅使用写模块，按照先更新扇区内容，再将更新的扇区内容信息载入文件系统交替执行。
        initializeFileSystemFinish: begin
          /// 转让文件使用权
          //SDIOReadWrite<=SDIOWrite;
          workState<=initializeFinish;

        end
        updateFileSystem: begin
          
          //  sendData<=FileSaveDataBlock[blockAddress];
        end
        default: begin
          //workState   <= inReset;
        end
      endcase
    end  /// 系统工作
    /*
    else begin
      FileSaveDataBlock[0] <= longFileName;
      FileSaveDataBlock[4] <= shortFileName;
    end*/
  end
  /// 要读的扇区地址
  reg [31:0] readSectorAddress;
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
  wire readSDClock;
  wire readSDCMD;
  wire [0:0] readSDdata;
  sd_reader #(
      .CLK_DIV(CLK_DIV)
  ) readAndInit (
      .rstn     (rstn),
      .clk      (clk),
      .sdclk    (readSDClock),
      .sdcmd    (readSDCMD),
      .sddat0   (readSDdata),
      .card_type  ( SDCardType      ),
      .card_stat(SDcardState),
      .rstart   (readStart),
      .rsector  (readSectorAddress),
      .rbusy    (),
      .rdone    (reciveEnd),
      .outen    (inReciveData),
      .outaddr  (reciveDataAddress),
      .outbyte  (reciveData)
  );

  /// 读BPR代码，工作条件：reciveData
  always @(inReciveData or reciveEnd) begin
    if (rstn) begin
      /// 读BPR代码仅在初始化状态为读取BPR状态，即SDIO初始化完成状态使用。
      if (workState == initializeBPR) begin
        /// 当reciveEnd触发本模块时，代表数据接收完毕，BPR读取完毕。此时将状态机推入BPR读取完成状态
        if (reciveEnd) begin
          //        workState <= initializeBPRFinish;
        end
      /// reciveEnd信号未触发，即因为reciveData触发本模块，由此根据reciveData记录需要记录的BPR信息
        else if (inReciveData) begin
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
      end
    end
  end
  /// 读文件系统块代码，工作条件：reciveData或reciveEnd
  always @(inReciveData or reciveEnd) begin
    if (rstn) begin

      /// 读BPR代码仅在初始化状态为读取BPR状态，即SDIO初始化完成状态使用。
      if (workState == initializeFileSystem) begin
        /// 当reciveEnd触发本模块时，代表数据接收完毕，BPR读取完毕。此时将状态机推入BPR读取完成状态
        if (reciveEnd) begin
          //        workState <= initializeFileSystemFinish;
        end
      /// reciveEnd信号未触发，即因为reciveData触发本模块，由此根据reciveData记录需要记录的BPR信息
        else if (inReciveData) begin
          FileSaveDataBlock[reciveDataAddress] <= reciveData;
          /// blockAddressEnable未启用，代表此时刚刚进入读根文件路径状态，现进行一些文件信息初始化操作
        end
      end
    end
  end


  /// 要写的扇区地址
  reg [31:0] writeSectorAddress;
  /// 开始读
  reg writeStart;
  /// 收到的数据
  wire inSendData;
  /// SDIO读模块部分
  wire [31:0] sendDataAddress;
  /// SDIO当前读出来的模块
  reg [7:0] sendData;
  /// SDIO读结束
  wire sendEnd;

  /// SDIO
  wire writeSDClock;
  wire writeSDCMD;
  wire [0:0] writeSDdata;
  sd_reader #(
      .CLK_DIV(CLK_DIV)
  ) WriteAndUpdate (
      .rstn     (rstn),
      .clk      (clk),
      .sdclk    (writeSDClock),
      .sdcmd    (writeSDCMD),
      .sddat0   (writeSDdata),
      //    .card_type  ( card_type      ),
 //     .card_stat(SDcardState),
      .rstart   (readStart),
      .rsector  (readSectorAddress),
      .rbusy    (),
      .rdone    (sendEnd),
      .outen    (reciveData),
      .outaddr  (reciveDataAddress),
      .outbyte  (reciveData)
  );
  /// SDIO总线总裁
  always @(*) begin
    sendData <= FileSaveDataBlock[blockAddress];
  end
  assign sdclk = SDIOReadWrite ? writeSDClock : readSDClock;  /*
  assign sdcmd=readSDCMD;
  assign sddat0=readSDdata;
  */
  wireSelector SDIOCMDSelector (
      .theProvideWire ({writeSDCMD, readSDCMD}),
      .selectorIndex  (SDIOReadWrite),
      .theSelectorWire(sdcmd)
  );
  wireSelector SDIODataSelector (
      .theProvideWire ({writeSDData, readSDdata}),
      .selectorIndex  (SDIOReadWrite),
      .theSelectorWire(sddat0)
  );
endmodule
