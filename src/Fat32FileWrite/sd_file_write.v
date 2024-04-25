
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
    parameter CLK_FREQ = 'd20_000_000  //时钟频率
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
    input  wire rx
);
  /// 初始化initialize的状态
  reg [2:0] initializeState;
  localparam [2:0] inReset = 2'b00,
  /// 初始化SD卡驱动
  initializeSDIOFinish = 2'b01,

  /// 初始化读BPR表得到系统数据
  initializeBPRFinish = 2'b10,

  /// 初始化彻底完成
  initializeFinish = 2'b11;
  /// 状态类
  /// 通用扇区，大小为512字节，用于存储一个扇区的数据
  /// 文件系统写入块。当前的设计思路为:简单粗暴的将数据区的第一个文件所处扇区“格式化”，只保留一项文件属性数据
  reg [512*8-1:0] FileSaveDataBlock;
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
  /// FIFO先入先出，将串口数据保存，以及以块写入SD卡
  wr_fifo UartInputData (
      .rst(~sys_rst_n),  // input rst
      .wr_clk(clk),  // input wr_clk
      .rd_clk(clk),  // input rd_clk
      .din(rx_data),  // input [7 : 0] din
      .wr_en(rx_flag),  // input wr_en
      .rd_en(wr_req),  // input rd_en
      .dout(FIFOWriteOutData),  // output [7 : 0] dout
      .full(),  // output full
      .empty(),  // output empty
      .rd_data_count(wr_fifo_data_num)  // output [10 : 0] rd_data_count
  );
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
  /// FileLength低10位始终为0，即FileLength为512的整数倍
  assign fileLength[9:0] = 10'b0000000000;
  /// 系统初始化状态机
  always @(posedge clk or negedge rstn) begin
    /// 系统复位
    if (rstn == 0) begin
      initializeState <= inReset;
      blockAddressEnable <= 0;
    end  /// 系统初始化
    else if (initializeState != 2'b11) begin
      case (initializeState)
        /// 复位状态，此时需要先准备初始化SDIO
        inReset: begin

        end
        /// 初始化SDIO完成，此时需要开始读取BPR表，用于获取接下来文件读写所需要的一些参数
        /// 在此阶段，通用扇区用于记录第一个扇区的内容。
        initializeSDIOFinish: begin
          /// blockAddressEnable未启用，代表此时刚刚进入读BPR状态，现进行一些读BPR初始化操作
          if (blockAddressEnable == 0) begin

            blockAddressEnable <= 1;
          end  /// blockAddressEnable已启用，表示当前工作在读BPR状态
          else begin
            /// blockAddress每次自增，小于512表示未读满512个数据，即尚未读完
            if (blockAddress <= 10'h512) begin
              /// 读取的0号扇区，需要的数据保存在特定的字节处

            end  /// blockAddress大于512，表示已经读满512个数据，而在读取数据过程中，BPR中需要记录的信息已经写入相应寄存器，故接下来需要清空块数据，将其使用权交给后续文件更新
            else begin
              blockAddressEnable <= 0;
              initializeState <= initializeBPRFinish;
            end
          end
        end
        /// 初始化BPR表完成，现在开始读取根文件夹目录
        /// 注意！当前设计的是直接破坏掉文件目录，重新写入。如果需要优化，可以将这里优化成反复读取扇区，直至发现空扇区位置，创建文件系统并且锁定文件编辑位置。
        initializeBPRFinish: begin

          /// blockAddressEnable未启用，代表此时刚刚进入读根文件路径状态，现进行一些文件信息初始化操作
          if (blockAddressEnable == 0) begin
            blockAddressEnable <= 1;
          end  /// blockAddressEnable已启用，表示当前工作在读BPR状态
          else begin
            /// blockAddress每次自增，小于512表示未读满512个数据，即尚未读完
            if (blockAddress <= 10'h512) begin
              /// 作用是录入该扇区512个数据，由于SD卡一次性需要写入512字节数据，换而言之，对于32*2=64字节的文件属性，需要通过此操作备份其他不需要修改的448字节数据。
            end  
            /// blockAddress大于512，表示已经读满512个数据，而在读取数据过程中，BPR中需要记录的信息已经写入相应寄存器，故接下来需要清空块数据，将其使用权交给后续文件更新
            else begin
                /// 
              blockAddressEnable <= 0;
              initializeState <= initializeFinish;
            end
          end
        end
        default: begin

        end
      endcase
    end  /// 系统工作
    else begin
      FileSaveDataBlock[1*(32)*8-1:0*32*8] <= longFileName;
      FileSaveDataBlock[2*(32)*8-1:32*8]   <= shortFileName;
    end
  end
  /// 
  wire reciveData;
  /// SDIO读模块部分
wire [31:0]readAddress;
/// SDIO当前读出来的模块
wire [7:1]readData;

wire reciveEnd;
sd_reader #(
    .CLK_DIV    ( CLK_DIV        ),
    .SIMULATE   ( SIMULATE       )
) u_sd_reader (
    .rstn       ( rstn           ),
    .clk        ( clk            ),
    .sdclk      ( sdclk          ),
    .sdcmd      ( sdcmd          ),
    .sddat0     ( sddat0         ),
    .card_type  ( card_type      ),
    .card_stat  ( card_stat      ),
    .rstart     ( read_start     ),
    .rsector    ( read_sector_no ),
    .rbusy      (                ),
    .rdone      ( reciveEnd      ),
    .outen      ( reciveData         ),
    .outaddr    ( readAddress          ),
    .outbyte    ( readData          )
);

    /// 读BPR代码
    always @((initializeState = initializeSDIOFinish) and (posedge reciveData or reciveEnd)) begin
      /// 当reciveEnd触发本模块时，代表数据接收完毕，BPR读取完毕。此时将状态机推入BPR读取完成状态
      if(reciveEnd)begin
        initializeState<=initializeBPRFinish;
      end
      /// reciveEnd信号未触发，即因为reciveData触发本模块，由此根据reciveData记录需要记录的BPR信息
      if(reciveData)begin
                  case (readAddress)
                /// 0x0E，保留扇区数,占用2字节。小端模式，高位在高，低位在地
                'hE: begin
                  ReservedSectors[7:0] <= readData;
                end
                'hF: begin
                  ReservedSectors[15:8] <= readData;
                end
                /// 0x10,FAT表的份数
                'h10: begin
                  NumberOfFAT <= readData;
                end
                /// 0x24:每FAT扇区数，占用4个字节
                'h24: begin
                  theLengthOfFAT[7:0] <= readData;
                end
                'h25: begin
                  theLengthOfFAT[15:8] <= readData;
                end
                'h26: begin
                  theLengthOfFAT[23:16] <= readData;
                end
                'h27: begin
                  theLengthOfFAT[31:24] <= readData;
                end
              endcase
        end
      end
endmodule
