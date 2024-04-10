
module SDWriterMaster (
    input  wire        sys_clk,    //?????????,???50MHz
    input  wire        sys_rst_n,  //?????????,?????????????
    //SD???????????
    input  wire        sd_miso,    //?????????????
    output wire        sd_clk,     //SD??????????????
    output reg         sd_cs_n,    //?????????????
    output reg         sd_mosi,    //??????????????
    //??SD???????????
    input  wire        wr_en,      //??????????????????
    input  wire [31:0] wr_addr,    //???????????????????
    input  wire [15:0] wr_data,    //???????????
    output wire        wr_busy,    //??????????
    output wire        wr_req,     //???????????????????
    //??SD???????????

    output wire init_end  //SD?????????????
);

  wire        rd_en;  //?????????????????
  wire        rd_busy;  //??????????
  wire        rd_data_en;  //?????????????????
  wire [15:0] rd_data;  //???????????
  //********************************************************************//
  //****************** Parameter and Internal Signal *******************//
  //********************************************************************//
  //wire define
  wire        init_cs_n;  //???????????????????
  wire        init_mosi;  //????????????????????????????
  wire        wr_cs_n;  //???????????????????
  wire        wr_mosi;  //????????????????????????????
  wire        rd_cs_n;  //???????????????????
  wire        rd_mosi;  //????????????????????????????

  //********************************************************************//
  //***************************** Main Code ****************************//
  //********************************************************************//
  //sd_clk:SD??????????????
  assign sd_clk = !sys_clk;
  //SD?????????????
  always @(*)
    if (init_end == 1'b0) begin
      sd_cs_n <= init_cs_n;
      sd_mosi <= init_mosi;
    end else if (wr_busy == 1'b1) begin
      sd_cs_n <= wr_cs_n;
      sd_mosi <= wr_mosi;
    end else if (rd_busy == 1'b1) begin
      sd_cs_n <= rd_cs_n;
      sd_mosi <= rd_mosi;
    end else begin
      sd_cs_n <= 1'b1;
      sd_mosi <= 1'b1;
    end

  //********************************************************************//
  //************************** Instantiation ***************************//
  //********************************************************************//
  //------------- sd_init_inst -------------
  SDWriterInit SDDataInit (
      .sys_clk  (sys_clk),    //?????????,???50MHz
      .sys_rst_n(sys_rst_n),  //?????????,?????????????
      .miso     (sd_miso),    //?????????????

      .cs_n    (init_cs_n),  //????????????????
      .mosi    (init_mosi),  //??????????????
      .init_end(init_end)    //?????????????????
  );

  //------------- sd_write_inst -------------
  SDWriterRunner SDDataWrite (
      .sys_clk  (sys_clk),            //?????????,???50MHz
      .sys_rst_n(sys_rst_n),          //?????????,?????????????
      .miso     (sd_miso),            //?????????????
      .wr_en    (wr_en && init_end),  //??????????????????
      .wr_addr  (wr_addr),            //???????????????????
      .wr_data  (wr_data),            //???????????

      .cs_n   (wr_cs_n),  //????????????????
      .mosi   (wr_mosi),  //??????????????
      .wr_busy(wr_busy),  //??????????
      .wr_req (wr_req)    //???????????????????
  );

endmodule
