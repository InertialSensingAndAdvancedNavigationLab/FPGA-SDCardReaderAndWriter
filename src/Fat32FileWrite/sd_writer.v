
//--------------------------------------------------------------------------------------------------------
// Module  : sd_reader
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: A SD-host to initialize SD-card and read sector
//           Support CardType   : SDv1.1 , SDv2  or SDHCv2
// 单块写入
//--------------------------------------------------------------------------------------------------------

module sd_write #(
    parameter [2:0] CLK_DIV  = 3'd2,  // when clk =   0~ 25MHz , set CLK_DIV = 3'd1,
                                      // when clk =  25~ 50MHz , set CLK_DIV = 3'd2,
                                      // when clk =  50~100MHz , set CLK_DIV = 3'd3,
                                      // when clk = 100~200MHz , set CLK_DIV = 3'd4,
                                      // ......
    parameter       SIMULATE = 0
) (
    input wire theRealCLokcForDebug,
    // rstn active-low, 1:working, 0:reset
    input wire rstn,
    // clock
    input wire clk,
    // SDcard signals (connect to SDcard), this design do not use sddat1~sddat3.
    input wire sdclk,
    inout wire sddat0,  // FPGA only read SDDAT signal but never drive it
    // show card status
    input wire [31:0] writeSectorAddress,
    /// Write
    input wire StartWrite,
    // 输入的数据
    input wire [7:0] inByte,  // a byte of sector content
    output wire [31:0] theWriteBitIndex,
    output reg prepareNextByte,
    /// 块写入完成
    output reg writeBlockFinish,
    /// 接收来自于Reader的初始化
    input wire [1:0] theCard_type,  // 0=UNKNOWN    , 1=SDv1    , 2=SDv2  , 3=SDHCv2
    input wire [15:0] theRCA,
    /// SDCMD
    output reg [15:0] clkdiv,
    output reg start,
    output reg [15:0] precnt,
    output reg [5:0] cmd,
    output reg [31:0] arg,
    input wire busy,
    input wire done,
    input wire timeout,
    input wire syntaxe,
    input wire [31:0] resparg
);

  ByteAnalyze writeDebugger (
      .clk(theRealCLokcForDebug),
      .probe0(SDDataOut),
      .probe1(busy),
      .probe2({
        timeout,
        syntaxe,
        writeBlockFinish,
        resparg[8],
        resparg[12:9],
        sddat_stat,
        sdcmd_stat,
        theCRC,
        done,sddat0,sdclk
      }),
      //.probe2(resparg),
      .probe3(sendByte),
      .probe4(SDDataInput),
      .probe5(SDWritePrepareOk),
      .probe6(writeSectorAddress),
      .probe7(writeBitIndex)
  );

  reg SDDataOutEnable;
  reg SDDataOut = 1'b1;

  // sdcmd tri-state driver
  assign sddat0 = SDDataOutEnable ? SDDataOut : 1'bz;
  wire SDDataInput = SDDataOutEnable ? 1'b1 : sddat0;
  reg [7:0] sendByte;  // a byte of sector content
  reg [1:0] card_type;  // 0=UNKNOWN    , 1=SDv1    , 2=SDv2  , 3=SDHCv2
  /// 15BitCRC
  reg [15:0] theCRC;
  wire [15:0] theNextCRC;
  localparam [1:0] UNKNOWN = 2'd0,  // SD card type
  SDv1 = 2'd1, SDv2 = 2'd2, SDHCv2 = 2'd3;

  localparam [15:0] FASTCLKDIV = (16'd1 << CLK_DIV);
  localparam [15:0] SLOWCLKDIV = FASTCLKDIV * (SIMULATE ? 16'd5 : 16'd48);

  reg        start = 1'b0;
  reg [15:0] precnt = 0;
  reg [ 5:0] cmd = 0;
  reg [31:0] arg = 0;
  reg [15:0] clkdiv = SLOWCLKDIV;
  reg [31:0] theWriteSectorAddress = 0;


  reg        sdv1_maybe = 1'b0;
  reg [ 2:0] cmd8_cnt = 0;
  reg [15:0] rca = 0;

  localparam [3:0]
  /*CMD0      = 4'd0,
                 CMD8      = 4'd1,
                 CMD55_41  = 4'd2,
                 ACMD41    = 4'd3,
                 CMD2      = 4'd4,
                 CMD3      = 4'd5,
                 CMD7      = 4'd6,
                 CMD16     = 4'd7,*/
  // CMD16,设置写入块大小，暂时不使用
  setWriteBlockSize = 4'd7,
  /// 等待命令状态，CM24
  waitOrder = 4'd0, waitSDReady = 4'd1, prepareWrite = 4'd2, inWritting = 4'd3, checkOut = 4'd4,waitSaveFinish = 4'd5;

  reg [3:0] sdcmd_stat = waitOrder;
  //enum logic [3:0] {CMD0, CMD8, CMD55_41, ACMD41, CMD2, CMD3, CMD7, CMD16, waitOrder, prepareWrite, inWritting} sdcmd_stat = CMD0;

  reg       sdclkl = 1'b0;
  reg       SDWritePrepareOk;
  localparam [2:0] writeWait = 3'd0, writeDoing = 3'd1,
  /// 意义不明，准备去掉
  writeCRC = 3'd2,
  //
  writeDone = 3'd3,
  /// 写超时
  writeTimeOut = 3'd4;
  reg [ 2:0] sddat_stat = writeWait;

  //enum logic [2:0] {writeWait, writeDoing, writeCRC, writeDone, writeTimeOut} sddat_stat = writeWait;

  reg [31:0] writeBitIndex = 0;
  assign theWriteBitIndex = writeBitIndex;
  assign rbusy            = (sdcmd_stat != waitOrder);
  //assign writeBlockFinish = (sdcmd_stat == inWritting) && (sddat_stat == writeDone);



  task set_cmd;
    input [0:0] _start;
    input [15:0] _precnt;
    input [5:0] _cmd;
    input [31:0] _arg;
    //task automatic set_cmd(input _start, input[15:0] _precnt='0, input[5:0] _cmd='0, input[31:0] _arg='0 );
    begin
      start  <= _start;
      precnt <= _precnt;
      cmd    <= _cmd;
      arg    <= _arg;
    end
  endtask

  always @(posedge clk or negedge rstn)
    /// 说明：对于SD卡写入器，认为其初始化由SD读取完成，故当SD读卡器复位时，默认继承自写准备状态而非写重置状态
    if (~rstn) begin
      set_cmd(0, 0, 0, 0);
      /// 分频器，在初始化过程中，若没有产生超时与错误，那么将会在到达等待命令前一个状态设置该值为快速时钟
      clkdiv                <= FASTCLKDIV;
      /// 该值无所谓。事实上在启动模块时将重新设置
      theWriteSectorAddress <= 0;
      rca                   <= theRCA;
      /// sdv1_maybe的含义是，有可能是因为使用的sdv1的卡，导致了超时。显然针对于设计的平台，不应该使用sdv1，其应该默认交接0
      sdv1_maybe            <= 1'b0;
      /// 该值默认交接v2.1，即3，为例保险起见，通过传入SDreader的卡状态
      card_type             <= theCard_type;
      /// 理论上只有在读取命令结束后交接，即waitOrder状态交接
      sdcmd_stat            <= waitOrder;
      /// 超时计数器，理论上交接前不会产生超时
      cmd8_cnt              <= 0;
      SDWritePrepareOk      <= 0;
    end else begin
      set_cmd(0, 0, 0, 0);
      if (sdcmd_stat == inWritting) begin
        case (sddat_stat)
          writeTimeOut: begin
            // CM24，写入512字节的块。SD卡应该不需要擦除操作即可写入
            set_cmd(1, 96, 24, theWriteSectorAddress);
            sdcmd_stat <= prepareWrite;
          end
          writeDone: begin
            sdcmd_stat <= checkOut;
          end
          default: begin

          end
        endcase
      end  /// 当SDCMD处于空闲状态时，根据当前状态让SDCMD活跃，此时busy=done=0;
      else if (~busy) begin
        case (sdcmd_stat)
          waitOrder: begin
            writeBlockFinish <= 0;
            /// SDID空闲，可以使用
            if (StartWrite) begin
              /// 发送CMD13查询卡的状态，发送CMD13查询卡的状态
              set_cmd(1, 256, 13, {rca, 16'h0});
              ///theWriteSectorAddress <= (card_type == SDHCv2) ? writeSectorAddress : (writeSectorAddress << 9);
              sdcmd_stat <= waitSDReady;
              /// 清除SD准备状态，接下来在收到SD卡准备完成的信号后开始写入
              SDWritePrepareOk <= 0;
            end
          end
          /// 发送CMD13查询卡的状态，SDID空闲，可以使用，则发送CMD24，否则再次发送CMD13等待SD空闲
          waitSDReady: begin
            /// SD卡准备完成，发送CMD24写块
            set_cmd(1, 256, 13, {rca, 16'h0});
          end
          checkOut: begin
            set_cmd(1, 256, 13, {rca, 16'h0});
          end
          waitSaveFinish: begin
            writeBlockFinish<=0;
            sdcmd_stat<=waitOrder;
          end
        endcase
      end  /// 当SDCMD处于工作完成状态时，查看是何种状态的任务执行完毕,此时busy为下降沿，done为1个时钟周期高电平
      else if (done) begin
        case (sdcmd_stat)
          /// SD卡准备完成：检查SD卡是否准备完成，若SD卡准备完成则准备进入写块状态
          waitSDReady: begin
            if (~timeout && ~syntaxe && resparg[8]) begin
              sdcmd_stat <= prepareWrite;
              set_cmd(1, 96, 24,
                      (card_type == SDHCv2) ? writeSectorAddress : (writeSectorAddress << 9));
              theWriteSectorAddress <= (card_type == SDHCv2) ? writeSectorAddress : (writeSectorAddress << 9);
            end
          end
          prepareWrite: begin
            if (~timeout && ~syntaxe && resparg[8]  /*resparg[12:9]==4'b0100*/) begin
              sdcmd_stat <= inWritting;
            end
          end
          //理论上不存在，因为没有发送命令，但此时resparg会变为7表示正在保存数据
          checkOut: begin
            /// 进入了保存模式
            if (~timeout && ~syntaxe && resparg[8]  /*resparg[12:9]==4'b0111*/) begin
              writeBlockFinish <= 1;
              sdcmd_stat <= waitOrder;
            end
          end
          //校验完成 
          waitSaveFinish: begin
            /// 进入了保存模式
            if (~timeout && ~syntaxe && resparg[12:9]==4'b0100) begin
              writeBlockFinish <= 1;
            end
          end
          default: begin
            if (~timeout && ~syntaxe) begin

              //set_cmd(1, 256, 13, {rca, 16'h0});
              //sdcmd_stat <= inWritting;
              SDWritePrepareOk <= 1;
            end else begin
              SDWritePrepareOk <= 0;
              sdcmd_stat <= waitSDReady;
              //set_cmd(1, 128, 24, theWriteSectorAddress);
            end
          end
        endcase
      end 
      else begin
        /// checkout，此时总线处于忙且非完成状态，若检查到resparg[12:9]==4'd7，即正在保存数据，则发送完毕
           if (~timeout && ~syntaxe && resparg[12:9]==4'b0111) begin
            writeBlockFinish<=1;
            sdcmd_stat <= waitSaveFinish;
            end
      end
    end


  always @(posedge clk or negedge rstn) begin : SDDataAction
    if (~rstn) begin
      sdclkl          <= 1'b0;
      sddat_stat      <= writeWait;
      writeBitIndex   <= 0;
      SDDataOut       <= 1'bz;
      SDDataOutEnable <= 1'b0;
    end else begin
      sdclkl <= sdclk;
      ///下降沿发送数据
      if (sdclkl & ~sdclk) begin
        case (sdcmd_stat)
          /// 发送了cmd24写命令，事实上此时总线没有被占用，所以预拉高
          prepareWrite: begin
            sddat_stat <= writeWait;
            writeBitIndex <= 0;
            SDDataOut <= 1;
            SDDataOutEnable <= 1;
          end
          /// 写入数据状态：根据数据状态进行
          inWritting: begin
            case (sddat_stat)
              writeWait: begin
                // 等待数个周期
                writeBitIndex <= writeBitIndex + 1;
                if (writeBitIndex > 64) begin
                  /// 开始发送前先发送bit0。此处有可能是sddata<=1'bz，从而通过if
                  SDDataOut <= 0;
                  SDDataOutEnable <= 1;
                  sddat_stat <= writeDoing;
                  writeBitIndex <= 0;
                  sendByte <= 8'd0;//inByte;
                  prepareNextByte <= 1;
                  theCRC <= 0;
                end else begin
                  if(writeBitIndex > 1000000)      // according to SD datasheet, 1ms is enough to wait for DAT result, here, we set timeout to 1000000 clock cycles = 80ms (when SDCLK=12.5MHz)
                    sddat_stat <= writeTimeOut;
                  writeBitIndex <= writeBitIndex + 1;
                end
              end
              writeDoing: begin
                /// 下面的代码完成了数据装载，当地址指向00时，此时发送的数据为刚刚装载好的数据
                SDDataOut <= sendByte[3'd7-writeBitIndex[2:0]];
                theCRC <= theNextCRC;
                if (writeBitIndex[2:0] == 3'd7) begin
                  /// 因为数据已经装载，故允许随时准备下一个数据
                  sendByte <= 8'd0;//inByte;
                  /// 这样写是为了立刻装载
                  //SDDataOut <= inByte[3'd7];
                  prepareNextByte <= 1;
                  /// 本数据发送完成，计算本数据CRC,特别的，当发送完512字节，进入写CRC时，会装载最后一次

                end else begin
                  prepareNextByte <= 0;
                end
                if (writeBitIndex >= 512 * 8 - 1) begin
                  sddat_stat <= writeCRC;
                  writeBitIndex <= 0;
                  /// 发送结束，结束装载信号
                  prepareNextByte <= 0;
                end else begin
                  writeBitIndex <= writeBitIndex + 1;
                end
              end
              /// 发送2字节CRC校验
              writeCRC: begin
                theCRC<=inByte;
                SDDataOut <= theCRC[4'd15-writeBitIndex[3:0]];
                if (writeBitIndex == 'd16) begin
                  SDDataOut <= 1'b1;
                  writeBitIndex <= 0;
                  sddat_stat <= writeDone;
                end
                writeBitIndex <= writeBitIndex + 1;
              end
            endcase
          end
          ///检查数据状态，特点：将读取SDdata0的CRC校验。
          checkOut: begin
            /// 等待计数
              SDDataOutEnable <= 0;
            writeBitIndex <= writeBitIndex + 1;
            if (writeBitIndex > 8*32) begin
              writeBitIndex   <= 0;
              SDDataOutEnable <= 0;
              //sddat_stat <= writeDone;
            end

          end
          default: begin
            sddat_stat <= writeWait;
            writeBitIndex <= 0;
          end
        endcase
      end
    end
  end
  crc16_d1 CRC (
      .data_in(SDDataOut),
      .crc_in (theCRC),
      .crc_out(theNextCRC)
  );
endmodule
////////////////////////////////////////////////////////////////////////////////
// author 微信小程序: CRC在线计算及Verilog代码生成
// generate date   : 2024-5-4 17:45
// polynomial      : x^16 + x^12 + x^5 + 1;
// polynomial hex  : 1021
// data width      : 1
// polynomial width: 16
// convention      : the first serial bit is D[0]
////////////////////////////////////////////////////////////////////////////////
module crc16_d1 (
    input  [ 0:0] data_in,
    input  [15:0] crc_in,
    output [15:0] crc_out
);

  wire [ 0:0] d;
  wire [15:0] c;
  wire [15:0] newcrc;

  assign d = data_in;
  assign c = crc_in;

  assign newcrc[0] = d[0] ^ c[15];
  assign newcrc[1] = c[0];
  assign newcrc[2] = c[1];
  assign newcrc[3] = c[2];
  assign newcrc[4] = c[3];
  assign newcrc[5] = d[0] ^ c[4] ^ c[15];
  assign newcrc[6] = c[5];
  assign newcrc[7] = c[6];
  assign newcrc[8] = c[7];
  assign newcrc[9] = c[8];
  assign newcrc[10] = c[9];
  assign newcrc[11] = c[10];
  assign newcrc[12] = d[0] ^ c[11] ^ c[15];
  assign newcrc[13] = c[12];
  assign newcrc[14] = c[13];
  assign newcrc[15] = c[14];

  assign crc_out = newcrc;


endmodule
