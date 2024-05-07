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
    
    parameter [8*8-1:0] FileName    = {"DataName"},
    parameter [3*8-1:0] FileExternName    = "bin",
    parameter [1*8-1:0] FileSystemType    = 8'b00100000,
    parameter [1*8-1:0] SystemKeep    = 8'h18,
     parameter [2*8-1:0] FileCreateTime    = 8'b00000000,
     parameter [2*8-1:0] FileCreateDate    = 8'b00000000,
     parameter [2*8-1:0] FileTouchDate    = 8'b00000000,
     parameter [2*8-1:0] FileChangeTime    = 8'b00000000,
     parameter [2*8-1:0] FileChangeDate    = 8'b00000000,
    parameter ClusterShift = 5
     

) (
    input rstn,
    input wire updateClock,
    /// 
    input wire [4*8-1:0] theFileStartSector,
    input wire [4*8-1:0] FileLength,
    /// FIFO的特性为高位先出，BRAM的特性为低位先出，请使用BRAM缓存该数据，或修改该数据以配置FIFO高位先出
    output wire [32*8-1:0]   theFAT32FileName,
    output reg [7:0] verify
);
reg [3:0]shortFileNameIndex;
reg LoadData=0;
reg [7:0] theChar;
wire [11*8-1:0] theFileName;
assign theFileName={FileName,FileExternName};
always @(posedge updateClock ) begin
    if(~rstn)begin
        shortFileNameIndex<=10;
        verify<=0;
        LoadData=0;
    end
    else if((shortFileNameIndex>=0)&&(shortFileNameIndex<11)) begin
         begin
            if(LoadData)begin
                
            verify<=((verify&1)?8'h80:8'h0)+({1'b0,verify[7:1]})+theChar;
            shortFileNameIndex<=shortFileNameIndex-1;
                LoadData<=0;
            end
            else begin
                LoadData<=1;
                theChar[0]<=theFileName[{shortFileNameIndex,3'h0}];
                theChar[1]<=theFileName[{shortFileNameIndex,3'h1}];
                theChar[2]<=theFileName[{shortFileNameIndex,3'h2}];
                theChar[3]<=theFileName[{shortFileNameIndex,3'h3}];
                theChar[4]<=theFileName[{shortFileNameIndex,3'h4}];
                theChar[5]<=theFileName[{shortFileNameIndex,3'h5}];
                theChar[6]<=theFileName[{shortFileNameIndex,3'h6}];
                theChar[7]<=theFileName[{shortFileNameIndex,3'h7}];
            end
        end
    end
end
  genvar index;
  
  for ( index= 0;index< 8; index=index+1) begin
        assign theFAT32FileName[8*index+7:8*index]=FileName[8*(7-index)+7:8*(7-index)];
end
  for ( index= 0;index< 3; index=index+1) begin
        assign theFAT32FileName[8*(index+8)+7:8*(index+8)]=FileExternName[8*(2-index)+7:8*(2-index)];
end
assign theFAT32FileName[8*'hB+7:8*'hB]=FileSystemType;
assign theFAT32FileName[8*'hC+7:8*'hC]=SystemKeep;
assign theFAT32FileName[8*'hD+7:8*'hD]=SystemKeep;
assign theFAT32FileName[8*'hE+15:8*'hE]=FileCreateTime;
assign theFAT32FileName[8*'h10+15:8*'h10]=FileCreateDate;
assign theFAT32FileName[8*'h12+15:8*'h12]=FileTouchDate;
assign theFAT32FileName[8*'h14+15:8*'h14]=0;//theFileStartSector[31:16];
assign theFAT32FileName[8*'h16+15:8*'h16]=FileChangeTime;
assign theFAT32FileName[8*'h18+15:8*'h18]=FileChangeDate;
// 人为约定为第17个
assign theFAT32FileName[8*'h1A+15:8*'h1A]=ClusterShift;//theFileStartSector[15:0];
assign theFAT32FileName[8*'h1C+31:8*'h1C]=FileLength;
endmodule
/**
创建长文件名，长文件名貌似可以叠放，即每个长文件名可以支持26字节长度，即13个字。可以通过输出更多长文件名的形式来延长文件名，其方法是FileType置0延长
例: 假设每个长文件名只保留了1个数字，而文件名称为123456，则保存为：0x06:6,0x05:5,x04:4,0x03:3,x02:2,0x01:1,即依然是小端模式，高位在高，低位在低
**/
module CreatelongFileName #(
    /// FileType,为8'b00000000表示后面还是长文件名
    parameter [1*8-1:0] FileType     = 8'b01000001,
    /// 取字符串，即需要包含结尾\0，即实际字符个数+1
    parameter            FileNameLength = 13    ,
    //parameter [26*8-1:0] FileName     = {"SaveData.txt",16'd0,((26-FileNameLength)*8)'hFF}
    parameter [13*8-1:0] FileName     = {"SaveData.txt",8'h0}//,(13-FileNameLength){8'h0}}
) (
    /// 短文件的校验值，请事先计算好再将其传入
    input wire [1*8-1:0]verify,
    output wire [32*8-1:0]   theFAT32FileName
);
    
  genvar stringIndex;
  integer      index ;
assign theFAT32FileName[8*'h0+7:8*'h0]=FileType;
/*
    /// 长文件名为UTF16编码，对应于ASCII编码，将其置于高8位置
  for ( index= 1,stringIndex=0;stringIndex< 5; index=index+2,stringIndex=stringIndex+1) begin
    /// 前5个字
    //if(stringIndex<FileNameLength) begin
        assign theFAT32FileName[8*index+15:8*index]={FileName[8*(FileNameLength-stringIndex)-1:8*(FileNameLength-stringIndex)-8],8'h00};
    end else if(stringIndex==FileNameLength) begin
        assign theFAT32FileName[8*index+15:8*index]=16'h00;
    end else begin
        assign theFAT32FileName[8*index+15:8*index]=16'hFF;
    end*/
  for ( stringIndex=0;stringIndex< 5; stringIndex=stringIndex+1) begin
    /// 前5个字
    //index=(stringIndex*2+1);
    if(stringIndex<FileNameLength) begin
        assign theFAT32FileName[8*(stringIndex*2+1)+15:8*(stringIndex*2+1)]={8'h00,FileName[8*(FileNameLength-stringIndex)-1:8*(FileNameLength-stringIndex)-8]};
    end else if(stringIndex==FileNameLength) begin
        assign theFAT32FileName[8*(stringIndex*2+1)+15:8*(stringIndex*2+1)]=16'h00;
    end else begin
        assign theFAT32FileName[8*(stringIndex*2+1)+15:8*(stringIndex*2+1)]=16'hFF;
    end
end
assign theFAT32FileName[8*'hB+7:8*'hB]=8'h0F;
assign theFAT32FileName[8*'hC+7:8*'hC]=8'h0;
assign theFAT32FileName[8*'hD+7:8*'hD]=verify;/*
/// 长文件名中间6个字
  for ( index= 14,stringIndex=5;stringIndex< 11; index=index+2,stringIndex=stringIndex+1) begin
   // if(stringIndex<FileNameLength) begin
        assign theFAT32FileName[8*index+15:8*index]={FileName[8*(FileNameLength-stringIndex)-1:8*(FileNameLength-stringIndex)-8],8'h00};
    /*end else if(stringIndex==FileNameLength) begin
        assign theFAT32FileName[8*index+15:8*index]=16'h00;
    end else begin
        assign theFAT32FileName[8*index+15:8*index]=16'hFF;
    end
end*/
/// 长文件名中间6个字
  for ( stringIndex=5;stringIndex< 11; stringIndex=stringIndex+1) begin
    // index=(stringIndex*2+4)
    if(stringIndex<FileNameLength) begin
        assign theFAT32FileName[8*(stringIndex*2+4)+15:8*(stringIndex*2+4)]={8'h00,FileName[8*(FileNameLength-stringIndex)-1:8*(FileNameLength-stringIndex)-8]};
    end else if(stringIndex==FileNameLength) begin
        assign theFAT32FileName[8*(stringIndex*2+4)+15:8*(stringIndex*2+4)]=16'h00;
    end else begin
        assign theFAT32FileName[8*(stringIndex*2+4)+15:8*(stringIndex*2+4)]=16'hFF;
    end
end
/// 文件起始簇号
assign theFAT32FileName[8*'h1A+15:8*'h1A]=0;/*
/// 长文件最后2个字
  for ( index= 'h1C,stringIndex=11;stringIndex< 13; index=index+2,stringIndex=stringIndex+1) begin
   // if(stringIndex<FileNameLength) begin
        assign theFAT32FileName[8*index+15:8*index]={FileName[8*(FileNameLength-stringIndex)-1:8*(FileNameLength-stringIndex)-8],8'h00};
    end else if(stringIndex==FileNameLength) begin
        assign theFAT32FileName[8*index+15:8*index]=16'h00;
    end else begin
        assign theFAT32FileName[8*index+15:8*index]=16'hFF;
    end*/
/// 长文件最后2个字
  for ( stringIndex=11;stringIndex< 13; stringIndex=stringIndex+1) begin
    // index=(stringIndex*2+6)
    if(stringIndex<FileNameLength) begin
        assign theFAT32FileName[8*(stringIndex*2+6)+15:8*(stringIndex*2+6)]={8'h00,FileName[8*(FileNameLength-stringIndex)-1:8*(FileNameLength-stringIndex)-8]};
    end else if(stringIndex==FileNameLength) begin
        assign theFAT32FileName[8*(stringIndex*2+6)+15:8*(stringIndex*2+6)]=16'h00;
    end else begin
        assign theFAT32FileName[8*(stringIndex*2+6)+15:8*(stringIndex*2+6)]=16'hFF;
    end
end

endmodule