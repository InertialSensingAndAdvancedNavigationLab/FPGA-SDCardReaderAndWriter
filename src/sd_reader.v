
//--------------------------------------------------------------------------------------------------------
// Module  : sd_reader
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: A SD-host to initialize SD-card and read sector
//           Support CardType   : SDv1.1 , SDv2  or SDHCv2
//--------------------------------------------------------------------------------------------------------

module sd_reader #(
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
    /// 本模块工作在写入还是读取状态
    //    input ReadOrWrite,
    input wire sddat0,  // FPGA only read SDDAT signal but never drive it
    // show card status
    output wire [3:0] card_stat,  // show the sdcard initialize status
    output reg [1:0] card_type,  // 0=UNKNOWN    , 1=SDv1    , 2=SDv2  , 3=SDHCv2

    output reg [15:0] rca,
    // user read sector command interface (sync with clk)
    input wire rstart,
    input wire [31:0] rsector,
    output wire rbusy,
    output wire rdone,
    // sector data output interface (sync with clk)
    output reg outen,  // when outen=1, a byte of sector content is read out from outbyte
    output reg [8:0] outaddr,  // outaddr from 0 to 511, because the sector size is 512
    output reg [7:0] outbyte,  // a byte of sector content
    /// SDIO CMD控制器，
    /// 之所以将其移出reader，是因为对于一个读写系统而言，writer同样需要使用cmd，若两个模块各实现一次，则将浪费一定资源，并且需要对两者的inout线cmd进行选线，非常复杂
    /// 但是SDData，对于Reader，只是input，对于Writer，只是Output，其选线器相对较简单，且在项目中，应该有纯保存数据（直接定向写入，只要有文件系统能看到文件）和纯读取文件（只加载文件内容），故Reader与Writer单独实现

    output reg  [15:0] clkdiv,
    output reg         start,
    output reg  [15:0] precnt,
    output reg  [ 5:0] cmd,
    output reg  [31:0] arg,
    input  wire        busy,
    input  wire        done,
    input  wire        timeout,
    input  wire        syntaxe,
    input  wire [31:0] resparg
);
  initial {outen, outaddr, outbyte} = 0;

  localparam [1:0] UNKNOWN = 2'd0,  // SD card type
  SDv1 = 2'd1, SDv2 = 2'd2, SDHCv2 = 2'd3;

  localparam [15:0] FASTCLKDIV = (16'd1 << CLK_DIV);
  localparam [15:0] SLOWCLKDIV = FASTCLKDIV * (SIMULATE ? 16'd5 : 16'd48);

  reg [31:0] rsectoraddr = 0;

  reg        sdv1_maybe = 1'b0;
  reg [ 2:0] cmd8_cnt = 0;
  /// 加载顺序：复位
  localparam [3:0] CMD0 = 4'd0,
  /// 判断类型
  CMD8 = 4'd1,
  /// 
  CMD55_41 = 4'd2, ACMD41 = 4'd3,
  /// 获取SD卡CID序列
  CMD2 = 4'd4,
  /// 获取RCA地址
  CMD3 = 4'd5,
  // 选中SD卡
  CMD7 = 4'd6,
  /// 复位设置块大小，可以修改此，使得不是单块读
  CMD16 = 4'd7,
  /// 单个块读
  CMD17 = 4'd8, READING = 4'd9, READING2 = 4'd10;

  reg [3:0] sdcmd_stat = CMD0;
  //enum logic [3:0] {CMD0, CMD8, CMD55_41, ACMD41, CMD2, CMD3, CMD7, CMD16, CMD17, READING, READING2} sdcmd_stat = CMD0;

  reg       sdclkl = 1'b0;

  localparam [2:0] RWAIT = 3'd0, RDURING = 3'd1, RTAIL = 3'd2, RDONE = 3'd3, RTIMEOUT = 3'd4;

  reg [ 2:0] sddat_stat = RWAIT;

  //enum logic [2:0] {RWAIT, RDURING, RTAIL, RDONE, RTIMEOUT} sddat_stat = RWAIT;

  reg [31:0] ridx = 0;

  assign rbusy     = (sdcmd_stat != CMD17);
  assign rdone     = (sdcmd_stat == READING2) && (sddat_stat == RDONE);

  assign card_stat = sdcmd_stat;




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
    if (~rstn) begin
      set_cmd(0, 0, 0, 0);
      clkdiv      <= SLOWCLKDIV;
      rsectoraddr <= 0;
      rca         <= 0;
      sdv1_maybe  <= 1'b0;
      card_type   <= UNKNOWN;
      sdcmd_stat  <= CMD0;
      cmd8_cnt    <= 0;
    end else begin
      set_cmd(0, 0, 0, 0);
      if (sdcmd_stat == READING2) begin
        if (sddat_stat == RTIMEOUT) begin
          set_cmd(1, 96, 17, rsectoraddr);
          sdcmd_stat <= READING;
        end else if (sddat_stat == RDONE) sdcmd_stat <= CMD17;
      end else if (~busy) begin
        case (sdcmd_stat)
          CMD0:     set_cmd(1, (SIMULATE ? 512 : 64000), 0, 'h00000000);
          CMD8:     set_cmd(1, 512, 8, 'h000001aa);
          CMD55_41: set_cmd(1, 512, 55, 'h00000000);
          ACMD41:   set_cmd(1, 256, 41, 'h40100000);
          CMD2:     set_cmd(1, 256, 2, 'h00000000);
          CMD3:     set_cmd(1, 256, 3, 'h00000000);
          CMD7:     set_cmd(1, 256, 7, {rca, 16'h0});
          CMD16:    set_cmd(1, (SIMULATE ? 512 : 64000), 16, 'h00000200);
          CMD17:
          if (rstart) begin
            set_cmd(1, 96, 17, (card_type == SDHCv2) ? rsector : (rsector << 9));
            rsectoraddr <= (card_type == SDHCv2) ? rsector : (rsector << 9);
            sdcmd_stat  <= READING;
          end
        endcase
      end else if (done) begin
        case (sdcmd_stat)
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
          CMD16: if (~timeout && ~syntaxe) sdcmd_stat <= CMD17;
          default:  //READING :   
          if (~timeout && ~syntaxe) sdcmd_stat <= READING2;
          else set_cmd(1, 128, 17, rsectoraddr);
        endcase
      end
    end


  always @(posedge clk or negedge rstn)
    if (~rstn) begin
      outen   <= 1'b0;
      outaddr <= 0;
      outbyte <= 0;
      sdclkl  <= 1'b0;
      sddat_stat <= RWAIT;
      ridx    <= 0;
    end else begin
      outen   <= 1'b0;
      outaddr <= 0;
      sdclkl  <= sdclk;
      if (sdcmd_stat != READING && sdcmd_stat != READING2) begin
        sddat_stat <= RWAIT;
        ridx <= 0;
      end else if (~sdclkl & sdclk) begin
        case (sddat_stat)
          RWAIT: begin
            if (~sddat0) begin
              sddat_stat <= RDURING;
              ridx <= 0;
            end else begin
              if(ridx > 1000000)      // according to SD datasheet, 1ms is enough to wait for DAT result, here, we set timeout to 1000000 clock cycles = 80ms (when SDCLK=12.5MHz)
                sddat_stat <= RTIMEOUT;
              ridx <= ridx + 1;
            end
          end
          RDURING: begin
            outbyte[3'd7-ridx[2:0]] <= sddat0;
            if (ridx[2:0] == 3'd7) begin
              outen   <= 1'b1;
              outaddr <= ridx[11:3];
            end
            if (ridx >= 512 * 8 - 1) begin
              sddat_stat <= RTAIL;
              ridx <= 0;
            end else begin
              ridx <= ridx + 1;
            end
          end
          RTAIL: begin
            if (ridx >= 8 * 8 - 1) sddat_stat <= RDONE;
            ridx <= ridx + 1;
          end
        endcase
      end
    end


endmodule

