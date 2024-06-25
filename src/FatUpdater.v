/**
FAT表扇区:即SD卡的块，每一个扇区为一块，512字节
需要注意的是，当文件小于一簇时，其不需要访问FAT表，而当文件大于一簇，如1.5簇时，其需要占用向上取整，即2簇数据，因此，当第一次触发更新FA表时，其更新了当前FAT与指向下一扇区结束的FAT。往后每一次更新都是如此，都是N个已用扇区与N+1个要开辟的新扇区
**/
module FATListBlock #(
    parameter            theSizeofBlock             = 512,
    parameter            indexWidth                 = 32,
    parameter            inputFileInformationLength = 8 * 32 * 2,
    parameter [26*8-1:0] SaveFileName               = "SaveData.dat",
    parameter            FileNameLength             = 12,
    parameter            ClusterShift               = 5
) (
    input wire Clock,
    input wire [indexWidth-1:0] Address,
    output reg [7:0] Byte,
    input wire [7:0] SectorsPerCluster,
    input wire [31:0] fileSectorLength,
    output reg isReachEnd
);
reg [indexWidth-1:0] readAddress;
reg [indexWidth-1:0] NextFAT;
  always @(posedge Clock) begin : FATAction
  readAddress<=Address;
  NextFAT<=(Address>>>2)+1;
    ///FAT32保留区
    if (readAddress < 8) begin
      case (readAddress)
        'h0: begin
          Byte <= 8'hF8;
          isReachEnd<=0;
        end
        'h3: begin
          Byte <= 8'h0F;
        end
        default: begin
          Byte <= 8'hFF;
        end
      endcase
    end  /// 非文件锁占用扇区
    else if ((readAddress>>>2) < ClusterShift) begin
       case (readAddress[1:0])
        'h3: begin
          Byte <= 8'h0F;
        end
        default: begin
          Byte <= 8'hFF;
        end
    endcase
    end  /// 最后一个扇区，即下一个开辟的扇区，写入0FFFFFFF，测测来是+3，我不理解，大概原因可能是，以第一次触发为例：
    /// 效果应该是：5簇指向6簇，6簇0FFFFFFF
    /// 5簇：readAddress-ClusterShift=0，而fileSectorLength=1，需要+1，使得
    /// 6簇：readAddress-ClusterShift=1，而fileSectorLength=1；
    else if ((NextFAT - ClusterShift -1) * SectorsPerCluster == fileSectorLength) begin
      case (readAddress[1:0])
        'h3: begin
          Byte <= 8'h0F;
          isReachEnd<=1;
        end
        default: begin
          Byte <= 8'hFF;
        end
      endcase
    end  /// 前面使用的扇区，指向下一个扇区位置
    else if ((NextFAT - ClusterShift-1) * SectorsPerCluster < fileSectorLength) begin
      case (readAddress[1:0])
        0:Byte <= NextFAT[7:0];
        1:Byte <= NextFAT[15:8];
        2:Byte <= NextFAT[23:16];
        3:Byte <= NextFAT[31:24];
    endcase
    end
    else begin
          Byte <= 8'h00;
    end
  end
endmodule
/**
更新FAT表地址，每更新一簇，FAT表更新一次
**/
module UpdateFatStartAddress #(
    parameter            theSizeofBlock             = 512,
    parameter            indexWidth                 = 32,
    parameter            inputFileInformationLength = 8 * 32 * 2,
    parameter [26*8-1:0] SaveFileName               = "SaveData.dat",
    parameter            FileNameLength             = 12,
    parameter            ClusterShift               = 5
) (
    /// 初始化所需时钟
    input wire clock,
    /// 每簇扇区个数
    input wire [7:0] SectorsPerCluster,
    /// 已经写入的扇区个数
    input wire [31:0]fileSectorLength,
    /// 需要更新Fat表的标记
    output reg NeedUpdateFat,
    /// 从何个扇区开始写
    output reg  [31:0]FatStartSector,
    /// 从何处开始写
    output reg [indexWidth-1:0] StartAddress
);

always @(posedge clock) begin : UpdateFatStartAddressAction
    case (SectorsPerCluster)
        'b00000001: begin
            NeedUpdateFat<=1;
            FatStartSector<=((fileSectorLength-1)>>9);
            StartAddress<=FatStartSector<<9;
        end
        'b00000010: begin
            if(fileSectorLength[0]=='b0) NeedUpdateFat<=1;
            else NeedUpdateFat<=0;
            /// 除以512，一个扇区，再除以一簇
            FatStartSector<=((fileSectorLength-1)>>9)>>1;
            /// 这里有没有延时，我不是记得很清楚了，应该是这样写的，效果是非延时乘以512，一个扇区
            StartAddress<=FatStartSector<<9;
        end
        'b00000100: begin
            if(fileSectorLength[1:0]=='b0) NeedUpdateFat<=1;
            else NeedUpdateFat<=0;
            FatStartSector<=((fileSectorLength-1)>>9)>>2;
            StartAddress<=FatStartSector<<9;
        end
        'b00000100: begin
            if(fileSectorLength[2:0]=='b0) NeedUpdateFat<=1;
            else NeedUpdateFat<=0;
                FatStartSector<=((fileSectorLength-1)>>9)>>3;
                StartAddress<=FatStartSector<<9;
        end
        'b00000100: begin
            if(fileSectorLength[3:0]=='b0) NeedUpdateFat<=1;
            else NeedUpdateFat<=0;
                FatStartSector<=((fileSectorLength-1)>>9)>>4;
                StartAddress<=FatStartSector<<9;
        end
        'b00000100: begin
            if(fileSectorLength[4:0]=='b0) NeedUpdateFat<=1;
            else NeedUpdateFat<=0;
                FatStartSector<=((fileSectorLength-1)>>9)>>5;
                StartAddress<=FatStartSector<<9;
        end
        'b00000100: begin
            if(fileSectorLength[5:0]=='b0) NeedUpdateFat<=1;
            else NeedUpdateFat<=0;
                FatStartSector<=((fileSectorLength-1)>>9)>>6;
                StartAddress<=FatStartSector<<9;
        end
        'b00000100: begin
            if(fileSectorLength[6:0]=='b0) NeedUpdateFat<=1;
            else NeedUpdateFat<=0;
                FatStartSector<=((fileSectorLength-1)>>9)>>7;
                StartAddress<=FatStartSector<<9;
        end
        default: begin
        end
      endcase
  end
endmodule