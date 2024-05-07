/**
扇区:即SD卡的块，每一个扇区为一块，512字节
**/
/**
读取MBR或DBR信息，该扇区为事实上的0x00扇区，需要从MBR中加载BPR所在扇区地址
**/
module ReadMBRorDBR #(
    parameter theSizeofSectors = 'd512
) (
    /// 根路径地址所在扇区,若使用的是非SD卡设备，可以精确到字节，那么请自行乘以theSizeofSectors
    output reg [31:0] theBPRDirectory,
    /// 正在编辑该模块
    input wire isEdit,
    /// 编辑的地址（与扇区地址一致）
    input wire [8:0] EditAddress,
    /// 编辑的数据
    input wire [7:0] EditByte
);
  /// 采用边沿触发可能会导致亚稳态，可能原因是SDIO的时钟显然慢于系统时钟，可能该模块工作在20Mhz而SDIO小于之，慢数据抵达快数据产生该问题。
  always @(posedge isEdit) begin
    case (EditAddress)
      9'h1C6: begin
        theBPRDirectory[7:0] <= EditByte;
      end
      9'h1C7: begin
        theBPRDirectory[15:8] <= EditByte;
      end
      9'h1C8: begin
        theBPRDirectory[23:16] <= EditByte;
      end
      9'h1C9: begin
        theBPRDirectory[31:24] <= EditByte;
      end
    endcase
  end
endmodule
/**
读取BPR扇区，BPR扇区即使用SD读卡器所看到的0x00扇区。其在SD卡中的扇区并非0x00。事实上所有地址均需偏移MBR地址
**/
module ReadBPR #(
    parameter theSizeofSectors = 'd512
) (
    /// 根路径地址所在扇区,若使用的是非SD卡设备，可以精确到字节，那么请自行乘以theSizeofSectors
    output reg [31:0] theRootDirectory,
    /// 正在编辑该模块
    input wire isEdit,
    /// 编辑的地址（与扇区地址一致）
    input wire [8:0] EditAddress,
    /// 编辑的数据
    input wire [7:0] EditByte,
    /// 每簇扇区数，在计算文件起始位置时需要使用
    output reg [7:0] SectorsPerCluster,
    output reg [31:0] RootClusterNumber,
    /// 保留扇区数，位于BPB(BIOS Parameter Block)中。该项数据建议从0号扇区中读取，以获得更加兼容性。
    output reg [15:0] ReservedSectors
);

  /// 每FAT扇区数
  reg [31:0] theLengthOfFAT = 0;
  /// FAT表一般均为2，在此视为参数。当然，读取也行。
  reg [ 7:0] NumberOfFAT = 0;
  always @(posedge isEdit) begin
    case (EditAddress)
      'hD: begin
        SectorsPerCluster <= EditByte;
      end
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
      'h2C: begin
        RootClusterNumber[7:0] <= EditByte;
      end
      'h2D: begin
        RootClusterNumber[15:8] <= EditByte;
      end
      'h2E: begin
        RootClusterNumber[23:16] <= EditByte;
      end
      'h2F: begin
        RootClusterNumber[31:24] <= EditByte;
      end

    endcase
    //由于读BPR512字节，会保存最终结果
    theRootDirectory <= ReservedSectors + (theLengthOfFAT * NumberOfFAT);
  end
endmodule  
/**
FAT表扇区:即SD卡的块，每一个扇区为一块，512字节
需要注意的是，当文件小于一簇时，其不需要访问FAT表，而当文件大于一簇，如1.5簇时，其需要占用向上取整，即2簇数据，因此，当第一次触发更新FA表时，其更新了当前FAT与指向下一扇区结束的FAT。往后每一次更新都是如此，都是N个已用扇区与N+1个要开辟的新扇区
**/
module FATListBlock #(
    parameter            theSizeofBlock             = 512,
    parameter            indexWidth                 = 9,
    parameter            inputFileInformationLength = 8 * 32 * 2,
    parameter [26*8-1:0] SaveFileName               = "SaveData.dat",
    parameter            FileNameLength             = 12,
    parameter            ClusterShift               = 5
) (
    input wire Clock,
    input wire [indexWidth-1:0] Address,
    output reg [7:0] Byte,
    input wire [7:0] SectorsPerCluster,
    input wire [31:0] fileSectorLength
);
reg [indexWidth-1:0] readAddress;
  always @(posedge Clock) begin : FATAction
  readAddress<=Address;
    ///FAT32保留区
    if (readAddress < 8) begin
      case (readAddress)
        'h0: begin
          Byte <= 8'hF8;
        end
        'h3: begin
          Byte <= 8'h0F;
        end
        default: begin
          Byte <= 8'hFF;
        end
      endcase
    end  /// 非文件锁占用扇区
    else if ((readAddress>>2) < ClusterShift) begin
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
    else if (((readAddress>>2) - ClusterShift) * SectorsPerCluster == fileSectorLength) begin
      case (readAddress[1:0])
        'h3: begin
          Byte <= 8'h0F;
        end
        default: begin
          Byte <= 8'hFF;
        end
      endcase
    end  /// 前面使用的扇区，指向下一个扇区位置
    else if (((readAddress>>2) - ClusterShift) * SectorsPerCluster < fileSectorLength) begin
      if (readAddress[1:0] == 0) begin
        Byte <= readAddress[8:2] + 1;
      end else begin
        Byte <= 8'h00;
      end
    end else begin
      Byte <= 8'h00;
    end
  end
endmodule
/**
扇区:即SD卡的块，每一个扇区为一块，512字节
**/
module FileSystemBlock #(
    parameter            theSizeofBlock             = 512,
    parameter            indexWidth                 = 9,
    parameter            inputFileInformationLength = 8 * 32 * 2,
    parameter [26*8-1:0] SaveFileName               = "SaveData.dat",
    parameter            FileNameLength             = 12,
    parameter            ClusterShift               = 5
) (
    input theRealCLokcForDebug,
    input wire Clock,
    /// 文件块工作在:1:写入，0:读出
    input wire InputOrOutput,
    /// 编辑的地址（与扇区地址一致）
    input wire [indexWidth-1:0] writeAddress,
    /// 编辑的数据，不使用inout端口，以此实现编辑时亦可输出
    input wire [7:0] EditByte,
    input wire [indexWidth-1:0] readAddress,
    output wire [7:0] Byte,
    /// 检索新文件位置命令：默认一个文件4+4=8字节，512/8=64，默认为一个块中恰好有64个文件。若本扇区中不存在足以存放文件的新空间(包括不连续空间，为了只更新一个块，加速进度)，那么返回不存在
    input wire checkoutFileExit,
    /// 该信号表示当前扇区已经发现合适的文件存储位置，并且将文件数据写入该合适的位置
    output reg FileExist,
    /// 该信号表示当前扇区没有合适的存放信息处，请加载另一个（下一个）扇区，并且重新给出checkoutFileExit命令搜索合适的位置
    output reg FileNotExist,
    /// 文件保存的地址，注意，因为没有传入参数BPR的偏移地址，所以该值在使用时请加上外面计算的起始地址偏移地址
    output reg [31:0] fileStartSector,
    /// 文件变更信息，需要文件信息器提供，先写低，再写高
    input wire [inputFileInformationLength-1:0] theChangeFileInput,
    input wire [31:0] fileSystemSector,
    input wire [7:0] SectorsPerCluster,
    input wire [31:0] RootClusterNumber
);
  reg [7:0] RAM[theSizeofBlock-1:0];
  reg [8:0] theFileSaveAddress;

  //  genvar index;
  //assign Byte = RAM[readAddress];
  //assign Byte=(theFileSaveAddress<=readAddress&&readAddress<theFileSaveAddress+64)?(theChangeFileInput[(readAddress-thetheFileSaveAddress)*8]):(RAM[readAddress]);

  assign Byte[0] = theChangeFileInput[{readAddress, 3'h0}];
  assign Byte[1] = theChangeFileInput[{readAddress, 3'h1}];
  assign Byte[2] = theChangeFileInput[{readAddress, 3'h2}];
  assign Byte[3] = theChangeFileInput[{readAddress, 3'h3}];
  assign Byte[4] = theChangeFileInput[{readAddress, 3'h4}];
  assign Byte[5] = theChangeFileInput[{readAddress, 3'h5}];
  assign Byte[6] = theChangeFileInput[{readAddress, 3'h6}];
  assign Byte[7] = theChangeFileInput[{readAddress, 3'h7}];

  always @(posedge Clock) begin : RAMAction
    integer index;
    if (InputOrOutput) begin

      // RAM[writeAddress] <= EditByte;
    end else if (checkoutFileExit) begin
      if (  /*(RAM[1] != 'd0) || (RAM[0] != 'd0)*/ 1) begin
        /// 添加插入文件逻辑：可以寻找以32的倍数，连续inputFileInformationLength个字节为0x00的扇区地址，作为插入的地址
        FileExist <= 1;
        FileNotExist <= 0;
        /// 理论上新插入的文件位于最后，此时已经可以通过计算之前读过的文件中，利用起始地址与文件长度，得出最大（即最后）的未使用地址，作为本文件的开始地址
        fileStartSector <=fileSystemSector+(ClusterShift-RootClusterNumber)*SectorsPerCluster;
        theFileSaveAddress <= 0;
      end else begin
        FileNotExist <= 1;
      end
    end else if (FileExist && (~FileNotExist)) begin
      /*for (index = 0; index < 64; index = index + 1) begin
        RAM[index+theFileSaveAddress] <= theChangeFileInput[8*index];
     end*/
    end else begin
      FileExist <= 0;
      FileNotExist <= 0;

    end
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
    input  wire                  AddOnce,
    /// 复位信号，复位值由SaveDataAddress参数决定
    input  wire                  sys_rst_n,
    /// 当前计数值
    output reg  [CountWidth-1:0] NowCount
);
  always @(posedge AddOnce or negedge sys_rst_n) begin
    /// 系统归0
    if (sys_rst_n == 0) begin
      NowCount <= StartCount;
    end  /// 系统自增
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
    input  wire                  AddOnce,
    /// 复位信号，复位值由SaveDataAddress参数决定
    input  wire                  sys_rst_n,
    /// 当前计数值
    output reg  [CountWidth-1:0] NowCount
);
  always @(posedge AddOnce or negedge sys_rst_n) begin
    /// 系统归0
    if (sys_rst_n == 0) begin
      NowCount <= StartCount;
    end  /// 系统自增
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
    parameter wireWidth = 1,
    /// 需要选择的信号个数
    parameter SelectorNumber = 2,
    /// 选择信号的位宽
    parameter SelectorNumberWidth = 1
) (
    /// 提供以进行选择的信号
    inout wire [wireWidth*SelectorNumber-1:0] theProvideWire,
    /// 选择的信号地址顺序
    input wire [SelectorNumberWidth-1:0] selectorIndex,
    /// 最终选择以连接的信号
    inout wire [wireWidth-1:0] theSelectorWire
);  /*
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
  assign theProvideWire[0] = (selectorIndex == 1'b1) ? 1'bz : theSelectorWire;
  assign theProvideWire[1] = (selectorIndex == 1'b1) ? theSelectorWire : 1'bz;
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
