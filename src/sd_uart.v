`timescale  1ns/1ns

module  sd_uart
(
    input  wire Button,
    input   wire            sys_clk     ,   //输入工作时钟,频率50MHz
    input   wire            sys_rst_n   ,   //输入复位信号,低电平有�????
    input   wire            rx          ,   //串口发�?�数�????
    input   wire            sd_miso     ,   //主输入从输出信号

    output  wire            sd_clk      ,   //SD卡时钟信�????
    output  wire            sd_cs_n     ,   //片�?�信�????
    output  wire            sd_mosi     ,   //主输出从输入信号
        output  wire            tx              //串口接收数据

);

wire SystemClock;


clk_wiz_1 Hz20(.clk_in1(sys_clk),
.clk_out1(SystemClock));

ila_0 CatchData(
    .clk(sys_clk),
    .probe0     (sd_miso),   //主输入从输出信号
    .probe1      (sd_clk),   //SD卡时钟信�????
    .probe2     (sd_cs_n),   //片�?�信�????
    .probe3    (sd_mosi)  
);

ila_0 systemAttitue(
    .clk(sys_clk),
    .probe0     (SystemClock),   //主输入从输出信号
    .probe1      (sys_rst_n),   //SD卡时钟信�????
    .probe2     (sd_cs_n),   //片�?�信�????
    .probe3    (sd_mosi)  
);
WriteSDCardByUART uart_tx_inst
(
    .sys_clk     (SystemClock),   //输入工作时钟,频率50MHz
    .sys_rst_n   (sys_rst_n),   //输入复位信号,低电平有�????
   .rx          (rx),   //串口发�?�数�????
    .sd_miso     (sd_miso),   //主输入从输出信号

    .sd_clk      (sd_clk),   //SD卡时钟信�????
    .sd_cs_n     (sd_cs_n),   //片�?�信�????
    .sd_mosi    (sd_mosi)   , //主输出从输入信号
    .tx (tx)
);

endmodule