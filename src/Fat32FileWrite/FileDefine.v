/**
扇区:即SD卡的块，每一个扇区为一块，512字节
**/
module getTheRootDirectory #(
    /// 扇区大小，SD卡中块为512字节
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
获取系统短文件名称。注意，该模块并非"生成"短文件，而是给出指定文件的短文件名称，该模块用于定时备份时，提供新的文件属性。
**/
module CreateShortFileName #(
    
    parameter [8*8-1:0] FileName    = "Data",
    parameter [3*8-1:0] FileExternName    = "bin",
    parameter [1*8-1:0] FileSystemType    = 8'b00000000,
    parameter [1*8-1:0] SystemKeep    = 8'b00000000,
     parameter [2*8-1:0] FileCreateTime    = 8'b00000000,
     parameter [2*8-1:0] FileCreateDate    = 8'b00000000,
     parameter [2*8-1:0] FileChangeTime    = 8'b00000000,
     parameter [2*8-1:0] FileChangeDate    = 8'b00000000
     

) (
    /// 
    input wire [4*8-2:0] theFileStartSector,
    input wire [4*8-2:0] FileLength,
    /// FIFO的特性为高位先出，BRAM的特性为低位先出，请使用BRAM缓存该数据，或修改该数据以配置FIFO高位先出
    output reg [32*8-1:0]   theFAT32FileName
);
    always @(*) begin
    //  theFAT32FileName[]
  end
endmodule
/**
创建长文件名，长文件名貌似可以叠放，即每个长文件名可以支持26字节长度，即13个字。可以通过输出更多长文件名的形式来延长文件名，其方法是FileType置0延长
例: 假设每个长文件名只保留了1个数字，而文件名称为123456，则保存为：0x06:6,0x05:5,x04:4,0x03:3,x02:2,0x01:1,即依然是小端模式，高位在高，低位在低
**/
module CreatelongFileName #(
    /// FileType,为8'b00000000表示后面还是长文件名
    parameter [1*8-1:0] FileType     = 8'b01000001,
    parameter [26*8-1:0] FILE_NAME     = "SaveData.txt"
) (
    /// 短文件的校验值，请事先计算好再将其传入
    input wire [1*8-1:0]verify,
    output reg [32*8-1:0]   theFAT32FileName
);
    
endmodule