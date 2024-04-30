
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
    // rstn active-low, 1:working, 0:reset
    input wire rstn,
    // clock
    input wire clk,
    // SDcard signals (connect to SDcard), this design do not use sddat1~sddat3.
    input wire sdclk,
    output reg sddat0,  // FPGA only read SDDAT signal but never drive it
    output wire rbusy,
    input wire inEnable,
    output reg [7:0] outbyte,  // a byte of sector content
    output wire byteDone,
    // show card status
    input wire [31:0] writeSectorAddress,
    /// Write
    input wire StartWrite,
    input wire inEnable,
    // 输入的数据
    input wire [7:0] inByte,  // a byte of sector content
    output wire [31:0]theWriteBitIndex,
    output reg prepareNextByte,
    /// 块写入完成
    output wire writeBlockFinish,
    /// 接收来自于Reader的初始化
    input wire [1:0] theCard_type,  // 0=UNKNOWN    , 1=SDv1    , 2=SDv2  , 3=SDHCv2
    
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

  reg [7:0] sendByte;  // a byte of sector content
   reg [1:0] card_type;  // 0=UNKNOWN    , 1=SDv1    , 2=SDv2  , 3=SDHCv2

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
                 setWriteBlockSize =4'd7,
                 /// 等待命令状态，CM24
                 waitOrder     = 4'd8,
                 prepareWrite   = 4'd9,
                 inWritting  = 4'd10;

  reg [3:0] sdcmd_stat = waitOrder;
  //enum logic [3:0] {CMD0, CMD8, CMD55_41, ACMD41, CMD2, CMD3, CMD7, CMD16, waitOrder, prepareWrite, inWritting} sdcmd_stat = CMD0;

  reg       sdclkl = 1'b0;

  localparam [2:0] writeWait = 3'd0, writeDoing = 3'd1,
  /// 意义不明，准备去掉
  writeTail = 3'd2,
  //
  writeDone = 3'd3,
  /// 写超时
   writeTimeOut = 3'd4;
  reg [ 2:0] sddat_stat = writeWait;

  //enum logic [2:0] {writeWait, writeDoing, writeTail, writeDone, writeTimeOut} sddat_stat = writeWait;

  reg [31:0] writeBitIndex = 0;
assign theWriteBitIndex=writeBitIndex;
  assign rbusy     = (sdcmd_stat != waitOrder);
  assign writeBlockFinish     = (sdcmd_stat == inWritting) && (sddat_stat == writeDone);



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
    /*if (~rstn) begin
      set_cmd(0, 0, 0, 0);
      clkdiv      <= SLOWCLKDIV;
      theWriteSectorAddress <= 0;
      rca         <= 0;
      sdv1_maybe  <= 1'b0;
      card_type   <= UNKNOWN;
      sdcmd_stat  <= CMD0;
      cmd8_cnt    <= 0;
    end*/
    
  /// 说明：对于SD卡写入器，认为其初始化由SD读取完成，故当SD读卡器复位时，默认继承自写准备状态而非写重置状态
    if (~rstn) begin
      set_cmd(0, 0, 0, 0);
      /// 分频器，在初始化过程中，若没有产生超时与错误，那么将会在到达等待命令前一个状态设置该值为快速时钟
      clkdiv      <= FASTCLKDIV;
      /// 该值无所谓。事实上在启动模块时将重新设置
      theWriteSectorAddress <= 0;
      rca         <= 0;
      /// sdv1_maybe的含义是，有可能是因为使用的sdv1的卡，导致了超时。显然针对于设计的平台，不应该使用sdv1，其应该默认交接0
      sdv1_maybe  <= 1'b0;
      /// 该值默认交接v2.1，即3，为例保险起见，通过传入SDreader的卡状态
      card_type   <= theCard_type;
      /// 理论上只有在读取命令结束后交接，即waitOrder状态交接
      sdcmd_stat  <= waitOrder;
      /// 超时计数器，理论上交接前不会产生超时
      cmd8_cnt    <= 0;
    end
     else begin
      set_cmd(0, 0, 0, 0);
      if (sdcmd_stat == inWritting) begin
        if (sddat_stat == writeTimeOut) begin
          // CM24，写入512字节的块。SD卡应该不需要擦除操作即可写入
          set_cmd(1, 96, 24, theWriteSectorAddress);
          sdcmd_stat <= prepareWrite;
        end else if (sddat_stat == writeDone) sdcmd_stat <= waitOrder;
      end else if (~busy) begin
        case (sdcmd_stat)
        /*
          CMD0:     set_cmd(1, (SIMULATE ? 512 : 64000), 0, 'h00000000);
          CMD8:     set_cmd(1, 512, 8, 'h000001aa);
          CMD55_41: set_cmd(1, 512, 55, 'h00000000);
          ACMD41:   set_cmd(1, 256, 41, 'h40100000);
          CMD2:     set_cmd(1, 256, 2, 'h00000000);
          CMD3:     set_cmd(1, 256, 3, 'h00000000);
          CMD7:     set_cmd(1, 256, 7, {rca, 16'h0});
          CMD16:    set_cmd(1, (SIMULATE ? 512 : 64000), 16, 'h00000200);*/
          waitOrder:
          /// SDID空闲，可以使用
          if (StartWrite) begin
            set_cmd(1, 96, 24, (card_type == SDHCv2) ? writeSectorAddress : (writeSectorAddress << 9));
            theWriteSectorAddress <= (card_type == SDHCv2) ? writeSectorAddress : (writeSectorAddress << 9);
            sdcmd_stat  <= prepareWrite;
          end
        endcase
      end else if (done) begin
        case (sdcmd_stat)
        /*
          CMD0: sdcmd_stat <= CMD8;
          CMD8:
          if (~timeout && ~syntaxe && resparg[7:0] == 8'haa) begin
            sdcmd_stat <= CMD55_41;
          end else if (timeout) begin
            cmd8_cnt <= cmd8_cnt + 3'd1;
            if (cmd8_cnt == 3'b111) begin
              sdv1_maybe <= 1'b1;
              sdcmd_stat <= CMD55_41;
            end
          end
          CMD55_41: if (~timeout && ~syntaxe) sdcmd_stat <= ACMD41;
          ACMD41:
          if (~timeout && ~syntaxe && resparg[31]) begin
            card_type  <= sdv1_maybe ? SDv1 : (resparg[30] ? SDHCv2 : SDv2);
            sdcmd_stat <= CMD2;
          end else begin
            sdcmd_stat <= CMD55_41;
          end
          CMD2: if (~timeout && ~syntaxe) sdcmd_stat <= CMD3;
          CMD3:
          if (~timeout && ~syntaxe) begin
            rca <= resparg[31:16];
            sdcmd_stat <= CMD7;
          end
          CMD7:
          if (~timeout && ~syntaxe) begin
            clkdiv <= FASTCLKDIV;
            sdcmd_stat <= CMD16;
          end
          CMD16: if (~timeout && ~syntaxe) sdcmd_stat <= waitOrder;
          */
          default:  //prepareWrite :   
          if (~timeout && ~syntaxe) sdcmd_stat <= inWritting;
          else set_cmd(1, 128, 24, theWriteSectorAddress);
        endcase
      end
    end


  always @(posedge clk or negedge rstn)
    if (~rstn) begin
      outbyte <= 0;
      sdclkl  <= 1'b0;
      sddat_stat <= writeWait;
      writeBitIndex    <= 0;
    end else begin
      sdclkl  <= sdclk;
      if (sdcmd_stat != prepareWrite && sdcmd_stat != inWritting) begin
        sddat_stat <= writeWait;
        writeBitIndex <= 0;
      end else if (~sdclkl & sdclk) begin
        case (sddat_stat)
          writeWait: begin
            if (~sddat0) begin
              sddat_stat <= writeDoing;
              writeBitIndex <= 0;
            end else begin
              if(writeBitIndex > 1000000)      // according to SD datasheet, 1ms is enough to wait for DAT result, here, we set timeout to 1000000 clock cycles = 80ms (when SDCLK=12.5MHz)
                sddat_stat <= writeTimeOut;
              writeBitIndex <= writeBitIndex + 1;
            end
          end
          writeDoing: begin
            sddat0 <= sendByte[3'd7-writeBitIndex[2:0]];
            if (writeBitIndex[2:0] == 3'd0) begin
              /// 因为数据已经装载，故允许随时准备下一个数据
              sendByte<=inByte;
              prepareNextByte<=1;
            end
            else begin
              prepareNextByte<=0;
            end
            if (writeBitIndex >= 512 * 8 - 1) begin
              sddat_stat <= writeTail;
              writeBitIndex <= 0;
            end else begin
              writeBitIndex <= writeBitIndex + 1;
            end
          end
          writeTail: begin
            if (writeBitIndex >= 8 * 8 - 1) sddat_stat <= writeDone;
            writeBitIndex <= writeBitIndex + 1;
          end
        endcase
      end
    end


endmodule

