/**
扇区:即SD卡的块，每一个扇区为一块，512字节
**/
module ReadBPR #(
    parameter theSizeofSectors='d512
)(
    /// 保留扇区数，位于BPB(BIOS Parameter Block)中。该项数据建议从0号扇区中读取，以获得更加兼容性。
    input wire [15:0]    ReservedSectors,
    /// 每FAT扇区数
    input wire [31:0]    theLengthOfFAT,
    /// FAT表一般均为2，在此视为参数。当然，读取也行。
    input wire [8:0] NumberOfFAT ,
    /// 根路径地址所在扇区,若使用的是非SD卡设备，可以精确到字节，那么请自行乘以theSizeofSectors
    output reg [31:0]   theRootDirectory
);

  always @(*) begin
      theRootDirectory <= ReservedSectors + theLengthOfFAT*NumberOfFAT;
  end
endmodule
/**
计数器
**/
module Count #(
  parameter CountWidth = 32,
  parameter StartCount = 32'h0
) (
    /// 自增信号，上升沿有效
    input  wire        AddOnce,
    /// 复位信号，复位值由SaveDataAddress参数决定
    input  wire        sys_rst_n,
    /// 当前计数值
    output reg  [CountWidth-1:0] NowCount  
);
  always @(posedge AddOnce or negedge sys_rst_n) begin
    /// 系统归0
    if (sys_rst_n == 0) begin
      NowCount <= StartCount;
    end 
    /// 系统自增
    else begin
      NowCount <= StartCount + 1;
    end
  end
endmodule


/**
计数器
**/
module CountWithSpecifileInitiziton #(
  parameter CountWidth = 32,
  parameter StartCount = 32'h0
) (
    /// 自增信号，上升沿有效
    input  wire        AddOnce,
    /// 复位信号，复位值由SaveDataAddress参数决定
    input  wire        sys_rst_n,
    /// 当前计数值
    output reg  [CountWidth-1:0] NowCount  
);
  always @(posedge AddOnce or negedge sys_rst_n) begin
    /// 系统归0
    if (sys_rst_n == 0) begin
      NowCount <= StartCount;
    end 
    /// 系统自增
    else begin
      NowCount <= StartCount + 1;
    end
  end
endmodule