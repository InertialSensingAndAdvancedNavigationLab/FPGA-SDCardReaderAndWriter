
module  sd_uart
(
    input   wire            sys_clk     ,   //输入工作时钟,频率50MHz
    input   wire            uart_rxd          ,   //串口发???数???
    input   wire            sd_miso     ,   //主输入从输出信号

    output  wire            sd_clk      ,   //SD卡时钟信???
    output  wire            sd_cs_n     ,   //片???信???
    output  wire            sd_mosi     ,   //主输出从输入信号
        output  wire            uart_txd              //串口接收数据

);
WriteSDCardByUART uart_tx_inst
(
    .sys_clk     (sys_clk),   //输入工作时钟,频率50MHz
    .sys_rst   (1'b0),   //输入复位信号,低电平有???
   .rx          (uart_rxd),   //串口发???数???
    .sd_miso     (sd_miso),   //主输入从输出信号

    .sd_clk      (sd_clk),   //SD卡时钟信???
    .sd_cs_n     (sd_cs_n),   //片???信???
    .sd_mosi    (sd_mosi)   , //主输出从输入信号
    .tx (uart_txd)
);

endmodule