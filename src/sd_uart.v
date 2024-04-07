`timescale  1ns/1ns

module  sd_uart
(
    input  wire Button,
    input   wire            sys_clk     ,   //输入工作时钟,频率50MHz
    inout   wire            sys_rst_n   ,   //输入复位信号,低电平有�????
    input   wire            rx          ,   //串口发�?�数�????
    input   wire            sd_miso     ,   //主输入从输出信号

    output  wire            sd_clk      ,   //SD卡时钟信�????
    output  wire            sd_cs_n     ,   //片�?�信�????
    output  wire            sd_mosi     ,   //主输出从输入信号
        output  wire            tx              //串口接收数据

);
WriteSDCardByUART uart_tx_inst
(
    .sys_clk     (sys_clk),   //输入工作时钟,频率50MHz
    .sys_rst   (~sys_rst_n),   //输入复位信号,低电平有�????
   .rx          (rx),   //串口发�?�数�????
    .sd_miso     (sd_miso),   //主输入从输出信号

    .sd_clk      (sd_clk),   //SD卡时钟信�????
    .sd_cs_n     (sd_cs_n),   //片�?�信�????
    .sd_mosi    (sd_mosi)   , //主输出从输入信号
    .tx (tx)
);

endmodule