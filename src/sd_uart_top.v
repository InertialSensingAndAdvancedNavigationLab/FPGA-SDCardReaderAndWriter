
module  sd_uart
(
    input   wire            sys_clk     ,   //���빤��ʱ��,Ƶ��50MHz
    input   wire            uart_rxd          ,   //���ڷ�???��???
    input   wire            sd_miso     ,   //�����������ź�

    output  wire            sd_clk      ,   //SD��ʱ����???
    output  wire            sd_cs_n     ,   //Ƭ???��???
    output  wire            sd_mosi     ,   //������������ź�
        output  wire            uart_txd              //���ڽ�������

);
WriteSDCardByUART uart_tx_inst
(
    .sys_clk     (sys_clk),   //���빤��ʱ��,Ƶ��50MHz
    .sys_rst   (1'b0),   //���븴λ�ź�,�͵�ƽ��???
   .rx          (uart_rxd),   //���ڷ�???��???
    .sd_miso     (sd_miso),   //�����������ź�

    .sd_clk      (sd_clk),   //SD��ʱ����???
    .sd_cs_n     (sd_cs_n),   //Ƭ???��???
    .sd_mosi    (sd_mosi)   , //������������ź�
    .tx (uart_txd)
);

endmodule