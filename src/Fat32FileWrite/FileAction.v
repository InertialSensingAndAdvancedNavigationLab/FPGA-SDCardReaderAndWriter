/**
扇区:即SD卡的块，每一个扇区为一块，512字节
**/
module ReadBPR #(
    parameter theSizeofSectors='d512
)(
    /// 根路径地址所在扇区,若使用的是非SD卡设备，可以精确到字节，那么请自行乘以theSizeofSectors
    output reg [31:0]   theRootDirectory,
    /// 正在编辑该模块
    input wire isEdit,
    /// 编辑的地址（与扇区地址一致）
    input wire [9:0] EditAddress,
    /// 编辑的数据
    input wire[7:0] EditByte
);

    /// 保留扇区数，位于BPB(BIOS Parameter Block)中。该项数据建议从0号扇区中读取，以获得更加兼容性。
    reg [15:0]    ReservedSectors;
    /// 每FAT扇区数
    reg [31:0]    theLengthOfFAT;
    /// FAT表一般均为2，在此视为参数。当然，读取也行。
    reg [8:0] NumberOfFAT;

  always @(posedge isEdit) begin
          case (EditAddress)
            /// 0x0E，保留扇区数,占用2字节。小端模式，高位在高，低位在地
            'hE: begin
              ReservedSectors[7:0] <= EditByte;
            end
            'hF: begin
              ReservedSectors[15:8] <= EditByte;
            end
            /// 0x10,FAT表的份数
            'h10: begin
              NumberOfFAT <= EditByte;
            end
            /// 0x24:每FAT扇区数，占用4个字节
            'h24: begin
              theLengthOfFAT[7:0] <= EditByte;
            end
            'h25: begin
              theLengthOfFAT[15:8] <= EditByte;
            end
            'h26: begin
              theLengthOfFAT[23:16] <= EditByte;
            end
            'h27: begin
              theLengthOfFAT[31:24] <= EditByte;
            end
          endcase
  end
  /// 编辑结束的下降沿，即不再编辑，输出地址固定
  always @(*) begin
      theRootDirectory <= ReservedSectors + (theLengthOfFAT*NumberOfFAT);
  end
endmodule
/**
扇区:即SD卡的块，每一个扇区为一块，512字节
**/
module FileSystemBlock #(
    parameter theSizeofBlock= 512,
    parameter indexWidth = 10
)(
    /// 文件块工作在:1:写入，0:读出
    input wire InputOrOutput,
    /// 编辑的地址（与扇区地址一致）
    input wire [indexWidth-1:0] ByteAddress,
    /// 编辑的数据，不使用inout端口，以此实现编辑时亦可输出
    input wire[7:0] EditByte,
    output wire [7:0] Byte
);

reg [7:0] RAM [theSizeofBlock-1:0];
    /// 保留扇区数，位于BPB(BIOS Parameter Block)中。该项数据建议从0号扇区中读取，以获得更加兼容性。
    reg [15:0]    ReservedSectors;
    /// 每FAT扇区数
    reg [31:0]    theLengthOfFAT;
    /// FAT表一般均为2，在此视为参数。当然，读取也行。
    reg [8:0] NumberOfFAT ;

  always @(InputOrOutput) begin
            RAM[ByteAddress]<=EditByte;
  end
  assign Byte=RAM[ByteAddress];
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

/**
三态门数据线仲裁
**/
module wireSelector #(
  /// 信号宽度
  parameter wireWidth=1,
  /// 需要选择的信号个数
  parameter SelectorNumber=2,
  /// 选择信号的位宽
  parameter SelectorNumberWidth=1
) (
  /// 提供以进行选择的信号
  inout wire [wireWidth*SelectorNumber-1:0] theProvideWire,
  /// 选择的信号地址顺序
  input wire [SelectorNumberWidth-1:0] selectorIndex,
  /// 最终选择以连接的信号
  inout wire [wireWidth-1:0]theSelectorWire
);/*
genvar index;
genvar indexInGroup;
  for ( index= 0;index< wireWidth; index=index+1) begin
    
assign theSelectorWire[index]=theProvideWire[selectorIndex];

  for ( indexInGroup= 0;indexInGroup<SelectorNumber; indexInGroup=indexInGroup+1) begin
assign theProvideWire[indexInGroup*wireWidth+index]=(selectorIndex==indexInGroup)?theSelectorWire[index]:1'bz;
  end
  end
  
/*always @(*) begin
  genvar index;
  for ( index= 0;index< wireWidth; index=index+1) begin
    
  end
  if(theProvideWire[selectorIndex]==1'bz)begin
    theProvideWire[selectorIndex]<=theSelectorWire;
  end
  else begin
    theSelectorWire <=theProvideWire[selectorIndex];
  end
end*/
endmodule


/**
三态门数据线仲裁
**/
module twoWireSelector #(
) (
  /// 提供以进行选择的信号
  inout wire [1:0] theProvideWire,
  /// 选择的信号地址顺序
  input wire selectorIndex,
  /// 最终选择以连接的信号
  inout wire theSelectorWire
);
assign theSelectorWire=(selectorIndex==1'b1)?((theProvideWire[1]==1'bz)?1'bz:theProvideWire[1]):((theProvideWire[0]==1'bz)?1'bz:theProvideWire[0]);
assign theProvideWire[0]=(selectorIndex==1'b1)?1'bz:theSelectorWire;
assign theProvideWire[1]=(selectorIndex==1'b1)?theSelectorWire:1'bz;
/*always @(*) begin
  genvar index;
  for ( index= 0;index< wireWidth; index=index+1) begin
    
  end
  if(theProvideWire[selectorIndex]==1'bz)begin
    theProvideWire[selectorIndex]<=theSelectorWire;
  end
  else begin
    theSelectorWire <=theProvideWire[selectorIndex];
  end
end*/
endmodule