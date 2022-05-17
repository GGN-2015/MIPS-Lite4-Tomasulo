// -------------------- 基于 Tomasulo 算法 的 MIPS-Lite4 处理器设计 -------------------- //
/*
 * 学校：吉林大学
 * 作者：郭冠男
 * 学号：21200612
 * 日期：2022-05-06
 */


// -------------------- 设计时的一些基本原则 -------------------- //
/*
 * 1. 模块可以分为保留站模块和组合逻辑模块
 *    保留站模块的输出一定原自其内部的数据寄存器
 *    组合逻辑模块综合后一定不产生数据寄存器
 *
 * 2. 每一个执行部件都由一个保留站、一个结果暂存器 和 一个组合逻辑构成
 *
 * 3. 每个 reg 类型变量的行为都由紧随其后的一个 always 块定义
 *
 * 4. 36 位数据格式：{35: 数据是否就绪, 34..32: 源设备号, 31..0: 实际值}
 *    如果保留站中的数据已经就绪，则可以送入执行部件
 */


 //! -------------------- 待解决的问题 -------------------- !//
 //? 指令发射的同时，如果所需要使用的数据正在上 CDB，可能会错过读取机会
 //? 取指令条件：当前没有未发射的指令，当前 JMP 模块不工作，当前 CDB 上的源设备不是 JMP


// -------------------- 已经解决的问题 -------------------- //
//

`timescale 1ns/10ps


// -------------------- 组合逻辑：CDB 获取模块 -------------------- //
module FetchCDB (
    // 以下端口来自 CDB 的输出
    input             cdb_buzy,
    input      [2 :0] cdb_device,
    input      [31:0] cdb_value,

    // 以下端口为即将被传输的数据，可能就绪，可能未就绪
    input      [35:0] buffer_value,

    // 以下端口为经过读取 CDB 而分析得到的数据
    output reg [35:0] buffer_newValue
);
    always @(*) begin
        if(buffer_value[35]) begin // 如果数据已经就绪，不读取 cdb
            buffer_newValue = buffer_value;
        end
        else begin // 如果数据未就绪，试图读取 cdb
            if(cdb_buzy && cdb_device == buffer_value[34:32]) begin // cdb 输出的是我想要读取的
                //! 此处一定要记得判断 cdb_buzy
                buffer_newValue[35]    = 1;
                buffer_newValue[34:32] = 0;
                buffer_newValue[31: 0] = cdb_value;
            end
            else begin // cdb 输出的不是我想要读取的
                buffer_newValue <= buffer_value;
            end
        end
    end
endmodule


// -------------------- 所有执行部件以及其编号 -------------------- //
//! 使用集中控制的方法确定哪一个部件可以输出到 CDB
//! 当有多个部件同时想要占据 CDB 时，优先允许编号较小的部件占用 CDB
`define DEVICE_ADDER 3'd1 // 加减运算器
`define DEVICE_LOGIC 3'd2 // 逻辑运算器
`define DEVICE_DM    3'd3 // 数据存储器
`define DEVICE_JMP   3'd7 // 跳转元件


// -------------------- 加法/逻辑 运算保留站 -------------------- //
//! 指令能够发射的条件是设备空闲
//! 设备空闲的条件是 保留站空闲 并且 输出缓冲器空闲
//! 否则会出现误把前一条指令发送到 CDB 的结果，当作当前指令结果写回的情况
module BufferIn (
    // 以下四个端口数据来自 InsBuffer(指令发射缓冲寄存器)
    input       in_hasInput,  // 有效位
    input[2 :0] in_device,    // 指令发射缓冲器指定的目标设备号
    input[1 :0] in_algorithm, // 计算方式，不同部件对计算方式定义不同
    input[35:0] in_valueA,    // 左源操作数
    input[35:0] in_valueB,    // 右源操作数

    //! device_now 用来描述当前保留站是哪个执行部件的缓冲站
    input[2 : 0] device_now,  //? 这个端口一定从常数输入
    
    // 以下三个端口数据来自 CDB(通用数据总线)
    input       cdb_buzy,    // CDB 忙
    input[2 :0] cdb_device,  // CDB 的输出设备
    input[31:0] cdb_value,   // CDB 的输出值

    // 以下端口来自计算机基本框架
    input clk, // 时钟
    input rst, // 清零

    // 以下端口来自后继设备
    input nxt_buzy, // 加法结果暂存器 或 逻辑运算结果暂存器

    // 输出端口
    output reg        out_buzy,      // 当前设备是否忙
    output            out_ready,     // 当前设备中的数据是否就绪
    output reg [1 :0] out_algorithm, // 当前设备中缓冲的算法
    output reg [35:0] out_valueA,    // 左源操作数
    output reg [35:0] out_valueB     // 右源操作数
);
    assign out_ready = (out_valueA[35] && out_valueB[35]); //! 两个数据都就绪，则可进行加法

    //! fetch 模块保证在数据传输过程中也能正确读取 CDB 中的值
    wire [35:0] fetchCDB_valueA;
    FetchCDB U_FetchCDB_valueA(cdb_buzy, cdb_device, cdb_value, in_valueA, fetchCDB_valueA);
    wire [35:0] fetchCDB_valueB;
    FetchCDB U_FetchCDB_valueB(cdb_buzy, cdb_device, cdb_value, in_valueB, fetchCDB_valueB);

    always @(posedge clk) begin
        if(rst) begin 
            out_buzy      <= 0; // 用于启动时的清空操作
            out_algorithm <= 0;
            out_valueA    <= 0;
            out_valueB    <= 0;
        end
        else begin
            if(out_buzy) begin // 如果当前设备忙，数据已经准备好了，并且后继模块不忙，则下一边沿可以成功写入
                if(out_ready && !nxt_buzy) begin 
                    out_buzy      <= 0; // 因此清空数据
                    out_algorithm <= 0;
                    out_valueA    <= 0;
                    out_valueB    <= 0;
                end
                if(!out_ready) begin //? 如果数据未就绪，在 CDB 监听 valueA 和 valueB
                    if(cdb_buzy) begin
                        if(!out_valueA[35] && out_valueA[34:32] == cdb_device) begin //! 监听数据 A
                            out_valueA[35]    <= 1;
                            out_valueA[34:32] <= 0;
                            out_valueA[31: 0] <= cdb_value;
                        end
                        if(!out_valueB[35] && out_valueB[34:32] == cdb_device) begin //! 监听数据 B
                            out_valueB[35]    <= 1;
                            out_valueB[34:32] <= 0;
                            out_valueB[31: 0] <= cdb_value;
                        end
                    end
                    //! 由于 out_ready 是组合逻辑，所以不需要额外设置
                end
            end
            else begin // 如果当前设备不忙，并且当前指令使用当前执行部件，从输入获取微指令
                if(in_hasInput && in_device == device_now) begin
                    out_buzy      <= 1;
                    out_algorithm <= in_algorithm;
                    out_valueA    <= fetchCDB_valueA; //? 此处传输已经进行了更正
                    out_valueB    <= fetchCDB_valueB;
                end
            end
        end
    end
endmodule


// -------------------- 加法器算法合集 -------------------- //
`define ADDER_ALGO_NOP 0 // 直传
`define ADDER_ALGO_ADD 1 // 加法
`define ADDER_ALGO_SUB 2 // 减法
`define ADDER_ALGO_SLT 3 // 比较


// -------------------- 加法器组合逻辑 -------------------- //
module AdderComb (
    input      [31:0] in_valueA,
    input      [31:0] in_valueB,
    input      [1 :0] in_algorithm,
    output reg [31:0] out_answer //! 这里的 reg 会被综合成组合逻辑
);
    always @(*) begin
        case(in_algorithm)
            `ADDER_ALGO_NOP: out_answer <= in_valueA;                                             // 直传
            `ADDER_ALGO_ADD: out_answer <= in_valueA + in_valueB;                                 // 加法
            `ADDER_ALGO_SUB: out_answer <= in_valueA - in_valueB;                                 // 减法
            `ADDER_ALGO_SLT: out_answer <= {{(31){1'b0}}, (in_valueA < in_valueB ? 1'b1 : 1'b0)}; // 比较
        endcase
    end
    //! 关于溢出问题：以后再说，为了简洁这个版本先不处理了
endmodule


// -------------------- 加法器输出暂存器 -------------------- //
module AdderBufferOut (
    // 以下五个端口来自加法器保留站
    input        in_buzy,
    input        in_ready,
    input [1 :0] in_algorithm,
    input [35:0] in_valueA,
    input [35:0] in_valueB,

    // 以下端口来自计算机基本框架
    input clk,
    input rst,

    // 以下端口来自后继设备 (CDB 是暂存器的后继设备)
    input cdb_buzy,

    // 输出端口
    output reg        out_buzy,   // 保留站是否忙
    output reg [2 :0] out_device, // 加法器设备编号
    output reg [31:0] out_value   // 加法器结果
);
    //! 在未来的版本可能会在此处增加对溢出的处理
    wire [31:0] adderAnswer;
    AdderComb U_AdderComb(in_valueA[31:0], in_valueB[31:0], in_algorithm, adderAnswer); // 加法的组合逻辑电路

    always @(posedge clk) begin
        if(rst) begin
            out_buzy   <= 0; // 用于启动时的数据清空
            out_device <= `DEVICE_ADDER;
            out_value  <= 0;
        end
        else begin
            if(out_buzy) begin // 输出暂存器中有数据，检查 CDB 是否有输出条件
                if(!cdb_buzy) begin //! 由于加法器优先级最高，所以只要 CDB 空闲就一定能上 CDB
                    out_buzy  <= 0; //! 其他部件需要判断比自己优先的所有执行部件都没有输出，才可以输出到 CDB
                    out_value <= 0;
                end
            end
            else begin // 输出暂存器中没有数据，试图从加法缓冲器中获取
                if(in_buzy && in_ready) begin //! 一定要注意，未就绪的数据要在保留站中等待 CDB 广播
                    out_buzy  <= 1;
                    out_value <= adderAnswer;
                end
            end
        end
    end
endmodule


// -------------------- 逻辑运算器组合逻辑 -------------------- //
`define LOGIC_ALGO_OR  0
`define LOGIC_ALGO_AND 1
`define LOGIC_ALGO_NOT 2
`define LOGIC_ALGO_XOR 3

module LogicComb (
    input      [31:0] in_valueA,
    input      [31:0] in_valueB,
    input      [1 :0] in_algorithm,
    output reg [31:0] out_answer //! 这里的 reg 会被综合成组合逻辑
);
    always @(*) begin
        case(in_algorithm)
            `LOGIC_ALGO_OR : out_answer <= in_valueA | in_valueB; // 按位或
            `LOGIC_ALGO_AND: out_answer <= in_valueA & in_valueB; // 按位与
            `LOGIC_ALGO_NOT: out_answer <= ~in_valueA;            // 按位取反
            `LOGIC_ALGO_XOR: out_answer <= in_valueA ^ in_valueB; // 按位异或
        endcase
    end
endmodule


// -------------------- 逻辑运算输出暂存器 -------------------- //
module LogicBufferOut (
    // 以下五个端口来自逻辑缓冲站 //! 加法缓冲站和乘法缓冲站均使用 BufferIn 模块
    input        in_buzy,
    input        in_ready,
    input [1 :0] in_algorithm,
    input [35:0] in_valueA,
    input [35:0] in_valueB,

    // 以下端口来自计算机基本框架
    input clk,
    input rst,

    // 以下端口来自后继设备 (CDB 是暂存器的后继设备)
    input cdb_buzy,
    input dvc_adder_buzy, //! 如果加法器想要输出到 CDB，那么逻辑运算器不能输出

    // 输出端口
    output reg        out_buzy,   // 暂存器是否忙
    output reg [2 :0] out_device, // 逻辑运算器器设备编号
    output reg [31:0] out_value   // 逻辑运算器结果
);
    wire [31:0] logicAnswer;
    LogicComb U_LogicComb(in_valueA[31:0], in_valueB[31:0], in_algorithm, logicAnswer); // 逻辑运算的组合逻辑电路

    always @(posedge clk) begin
        if(rst) begin
            out_buzy   <= 0; // 用于启动时的数据清空
            out_device <= `DEVICE_LOGIC;
            out_value  <= 0;
        end
        else begin
            if(out_buzy) begin // 输出暂存器中有数据，检查 CDB 是否有输出条件
                if(!cdb_buzy && !dvc_adder_buzy) begin //! 加法器想要输出时 逻辑运算器不能输出
                    out_buzy  <= 0;
                    out_value <= 0;
                end
            end
            else begin // 输出暂存器中没有数据，试图从逻辑缓冲站中获取
                if(in_buzy && in_ready) begin //! 一定要注意，未就绪的数据要在保留站中等待 CDB 广播
                    out_buzy  <= 1;           //! 只有当数据就绪后，才能参与运算
                    out_value <= logicAnswer;
                end
            end
        end
    end
endmodule


// -------------------- 数据存储器(执行部件) -------------------- //
`define DM_SIZE      4096
`define DM_ALGO_BYTE 1
`define DM_ALGO_HALF 2 
`define DM_ALGO_WORD 3 

//! 存储器是一个特殊的设备，因此保留站与输出缓冲放在了一个模块里
module DataMemory (
    // 以下端口来自 InsBuffer (指令发射缓冲寄存器)
    input       in_hasInput,
    input[2 :0] in_device,
    input[1 :0] in_algorithm, // 操作数据长度：字节，半字，字
    input[35:0] in_valueA,    // 基址寄存器值
    input[35:0] in_valueB,    // 要写入的数据值
    input       in_DM_write,  // 是否写数据存储器，不写说明是读
    input       in_DM_sign,   // 读出数据是否带符号拓展
    input[15:0] in_DM_offset, // 地址偏移量 (需要带符号拓展)
    
    // 以下三个端口数据来自 CDB(通用数据总线) //! 输入输出缓冲站也需要等待 CDB 中的数据
    input       cdb_buzy,
    input[2 :0] cdb_device,
    input[31:0] cdb_value,

    // 以下端口来自计算机基本框架
    input clk,
    input rst,

    // 以下端口来自后继设备 (CDB 是暂存器的后继设备)
    input dvc_adder_buzy,
    input dvc_logic_buzy, //! 存储器只有在加法器和逻辑运算器都不想占用 CDB 时才能工作
    
    // 输出端口
    output reg        buffer_buzy, //! 保留站中是否有元素
    output reg        out_buzy,    // 暂存器是否要输出 //! 一定要注意，设备能接受输入的条件是保留站中没有元素
    output reg [2 :0] out_device,  // 存储器的设备号
    output reg [31:0] out_value    // 存储器中读取的数据
);
    // 以下寄存器为保留站寄存器
    reg [1 :0] buffer_algorithm;
    reg [35:0] buffer_valueA;    // 基地址
    reg [35:0] buffer_valueB;    // 将要写入的数据
    reg        buffer_DM_write;
    reg        buffer_DM_sign;
    reg [15:0] buffer_DM_offset; // 偏移地址

    //! 写内存时要求两个值都需要就绪，读内存时第二个值没有意义
    wire buffer_ready;
    assign buffer_ready = buffer_DM_write ? buffer_valueA[35] && buffer_valueB[35] : buffer_valueA[35];

    //! fetch 模块保证在数据传输过程中也能正确读取 CDB 中的值
    wire [35:0] fetchCDB_valueA;
    FetchCDB U_FetchCDB_valueA(cdb_buzy, cdb_device, cdb_value, in_valueA, fetchCDB_valueA);
    wire [35:0] fetchCDB_valueB;
    FetchCDB U_FetchCDB_valueB(cdb_buzy, cdb_device, cdb_value, in_valueB, fetchCDB_valueB);

    wire [31:0] buffer_addr; // 地址
    assign buffer_addr = buffer_valueA[31:0] + {{16{buffer_DM_offset[15]}}, buffer_DM_offset}; // 带符号拓展

    reg [7:0] DM[0:`DM_SIZE - 1]; //? 4KB RAM
    integer i;
    always @(posedge clk) begin // 数据存储器逻辑
        if(rst) begin
            for(i = 0; i < `DM_SIZE; i += 1) begin
                DM[i] <= 0;
            end
        end
        else begin
            if(buffer_buzy && buffer_ready && buffer_DM_write) begin // 可以写入存储器
                //! 存储器使用小端方式存储 32 位字
                case(buffer_algorithm)
                    `DM_ALGO_BYTE: begin
                        DM[buffer_addr + 0] <= buffer_valueB[7:0];
                    end
                    `DM_ALGO_HALF: begin
                        DM[buffer_addr + 0] <= buffer_valueB[7 :0];
                        DM[buffer_addr + 1] <= buffer_valueB[15:8];
                    end
                    `DM_ALGO_WORD: begin
                        DM[buffer_addr + 0] <= buffer_valueB[7 : 0];
                        DM[buffer_addr + 1] <= buffer_valueB[15: 8];
                        DM[buffer_addr + 2] <= buffer_valueB[23:16];
                        DM[buffer_addr + 3] <= buffer_valueB[31:24];
                    end
                endcase
            end
        end
    end

    // -------------------- 以下内容为保留站逻辑 -------------------- //
    always @(posedge clk) begin
        if(rst) begin
            buffer_buzy      <= 0;
            buffer_algorithm <= 0;
            buffer_valueA    <= 0;
            buffer_valueB    <= 0;
            buffer_DM_write  <= 0;
            buffer_DM_sign   <= 0;
            buffer_DM_offset <= 0;
        end
        else begin
            if(buffer_buzy) begin      // 如果当前 buffer 有内容
                if(buffer_ready) begin // 数据已经就绪
                    // 考虑当前指令是读和写两种情况
                    if(!buffer_DM_write) begin
                        if(!out_buzy) begin // 考虑下一级缓冲寄存器能否使用
                            //! 下一级缓冲寄存器负责读入清空前的数据
                            buffer_buzy      <= 0;
                            buffer_algorithm <= 0;
                            buffer_valueA    <= 0;
                            buffer_valueB    <= 0;
                            buffer_DM_write  <= 0;
                            buffer_DM_sign   <= 0;
                            buffer_DM_offset <= 0;
                        end
                    end
                    else begin // 写的情况，RAM 本身一定是可用的，直接清空数据
                        buffer_buzy      <= 0;
                        buffer_algorithm <= 0;
                        buffer_valueA    <= 0;
                        buffer_valueB    <= 0;
                        buffer_DM_write  <= 0;
                        buffer_DM_sign   <= 0;
                        buffer_DM_offset <= 0;
                    end
                end
                else begin // 数据未就绪
                    if(!buffer_valueA[35] && cdb_device == buffer_valueA[34:32]) begin // 可以读入数据 A
                        buffer_valueA[35]    <= 1;
                        buffer_valueA[34:32] <= 0;
                        buffer_valueA[31: 0] <= cdb_value;
                    end
                    if(buffer_DM_write && !buffer_valueB[35] && cdb_device == buffer_valueB[34:32]) begin // 可以读入数据 B
                        //! 读存储器不需要数据 B
                        buffer_valueB[35]    <= 1;
                        buffer_valueB[34:32] <= 0;
                        buffer_valueB[31: 0] <= cdb_value;
                    end
                end
            end
            else begin // 当前 buffer 中没有内容，从输入中读取
                if(in_hasInput && in_device == `DEVICE_DM) begin
                    buffer_buzy      <= 1;
                    buffer_algorithm <= in_algorithm;
                    buffer_valueA    <= fetchCDB_valueA;
                    buffer_valueB    <= fetchCDB_valueB; //? 此处传输已经得到了更正
                    buffer_DM_write  <= in_DM_write;
                    buffer_DM_sign   <= in_DM_sign;
                    buffer_DM_offset <= in_DM_offset;
                end
            end
        end
    end

    // -------------------- 以下内容为输出缓冲逻辑 -------------------- //
    always @(posedge clk) begin
        if(rst) begin // 硬件清零信号
            out_buzy   <= 0;
            out_device <= `DEVICE_DM;
            out_value  <= 0;
        end
        else begin
            if(!out_buzy) begin // 如果现在不忙，试图从缓冲站读入数据
                if(buffer_buzy && buffer_ready) begin
                    out_buzy  <= 1;
                    case(buffer_algorithm) //! 通过地址读出值，相当于组合逻辑电路
                        `DM_ALGO_BYTE: begin
                            out_value <= {{24{buffer_DM_sign ? DM[buffer_addr][7] : 1'b0}}, DM[buffer_addr]};
                        end
                        `DM_ALGO_HALF: begin
                            out_value <= {{16{buffer_DM_sign ? DM[buffer_addr + 1][7] : 1'b0}}, DM[buffer_addr + 1], DM[buffer_addr + 0]};
                        end
                        `DM_ALGO_WORD: begin //! 加载字的时候是否带符号拓展无关紧要
                            out_value <= {DM[buffer_addr + 3], DM[buffer_addr + 2], DM[buffer_addr + 1], DM[buffer_addr + 0]};
                        end
                    endcase
                end
            end
            else begin
                if(!cdb_buzy && !dvc_adder_buzy && !dvc_logic_buzy) begin // 只有当前两个设备都不工作时，第三个设备工作
                    out_buzy  <= 0;
                    out_value <= 0;
                end
            end
        end
    end
endmodule


// -------------------- 跳转器 -------------------- //
//! 如果跳转器正在工作，那么 IFU 不可以取出下一条指令
//! PC 从 CDB 获取跳转器输出的跳转结果
//! 如果 CDB 没有输出跳转结果，则 PC 默认 +4
`define JMP_ALGO_JMP   1 // 无条件跳转
`define JMP_ALGO_BEQ   2 // valueA =  valueB 跳转
module Jmp (
    // 以下端口来自指令发射缓冲器
    //! 跳转的目标地址可能是寄存器的值
    //! 也可能是一个可以通过 PC+4 和已知偏移量计算出的数
    //! 执行当前指令时，PC 的值已经 +4
    input        in_hasInput,
    input [2 :0] in_device,
    input [35:0] in_targetAddr,
    input [1 :0] in_algorithm,
    input [35:0] in_valueA,
    input [35:0] in_valueB,

    // 以下三个端口数据来自 CDB(通用数据总线) //! 输入输出缓冲站也需要等待 CDB 中的数据
    input       cdb_buzy,
    input[2 :0] cdb_device,
    input[31:0] cdb_value,

    // 以下端口来自计算机基本框架
    input clk,
    input rst,

    // 以下端口来自后继设备 (CDB 是暂存器的后继设备)
    input dvc_adder_buzy,
    input dvc_logic_buzy,
    input dvc_memory_buzy, //! 跳转模块只有在没人想要占用 CDB 时才能占用 CDB
    
    // 输出端口
    output reg        buffer_buzy,
    output reg        out_buzy,    // 暂存器是否要输出 //! 一定要注意，设备能接受输入的条件是保留站中没有元素
    output reg [2 :0] out_device,  // 存储器的设备号
    output reg [31:0] out_value    // 存储器中读取的数据
);
    //! 类似存储器，内置了一个保留站
    reg [35:0] buffer_targetAddr;
    reg [1 :0] buffer_algorithm;
    reg [35:0] buffer_valueA;
    reg [35:0] buffer_valueB;

    reg buffer_ready; //! 实际上会被综合成组合逻辑，无条件跳转不需要等待 valueA 与 valueB
    always @(*) begin
        if(buffer_algorithm == `JMP_ALGO_BEQ) buffer_ready = buffer_targetAddr[35] && buffer_valueA[35] && buffer_valueB[35]; else
        if(buffer_algorithm == `JMP_ALGO_JMP) buffer_ready = buffer_targetAddr[35]; else buffer_ready = 1; // 不跳转
    end

    //! fetch 模块保证在数据传输过程中也能正确读取 CDB 中的值
    wire [35:0] fetchCDB_valueA;
    FetchCDB U_FetchCDB_valueA(cdb_buzy, cdb_device, cdb_value, in_valueA, fetchCDB_valueA);
    wire [35:0] fetchCDB_valueB;
    FetchCDB U_FetchCDB_valueB(cdb_buzy, cdb_device, cdb_value, in_valueB, fetchCDB_valueB);
    wire [35:0] fetchCDB_targetAddr;
    FetchCDB U_FetchCDB_targetAddr(cdb_buzy, cdb_device, cdb_value, in_targetAddr, fetchCDB_targetAddr);

    // 以下为保留站寄存器行为逻辑
    always @(posedge clk) begin
        if(rst) begin
            buffer_buzy       <= 0;
            buffer_targetAddr <= 0;
            buffer_algorithm  <= 0;
            buffer_valueA     <= 0;
            buffer_valueB     <= 0;
        end
        else begin
            if(buffer_buzy) begin
                if(buffer_ready) begin // 如果缓冲区的数据已经准备就绪了，试图输出到下一个部件
                    if(!out_buzy) begin
                        buffer_buzy       <= 0; // 当前部件只需要考虑清空问题
                        buffer_targetAddr <= 0;
                        buffer_valueA     <= 0;
                        buffer_valueB     <= 0;
                    end
                end
                else begin // 如果数据未就绪，则在 CDB 监听
                    if(!buffer_targetAddr[35] && buffer_targetAddr[34:32] == cdb_device) begin // 监听 target
                        buffer_targetAddr[35]    <= 1;
                        buffer_targetAddr[34:32] <= 0;
                        buffer_targetAddr[31: 0] <= cdb_value;
                    end
                    //! 虽然有些情况 valueA, valueB不需要监听，但是我觉得监听一下也没问题
                    if(!buffer_valueA[35] && buffer_valueA[34:32] == cdb_device) begin
                        buffer_valueA[35]    <= 1;
                        buffer_valueA[34:32] <= 0;
                        buffer_valueA[31: 0] <= cdb_value;
                    end
                    if(!buffer_valueB[35] && buffer_valueB[34:32] == cdb_device) begin
                        buffer_valueB[35]    <= 1;
                        buffer_valueB[34:32] <= 0;
                        buffer_valueB[31: 0] <= cdb_value;
                    end
                end
            end
            else begin // 如果缓冲区中没有数据，试图从输入读入数据
                if(in_hasInput && in_device == `DEVICE_JMP) begin
                    buffer_buzy       <= 1;
                    buffer_targetAddr <= fetchCDB_targetAddr; //? 此处赋值已更正
                    buffer_algorithm  <= in_algorithm;
                    buffer_valueA     <= fetchCDB_valueA;
                    buffer_valueB     <= fetchCDB_valueB; //? 此处赋值已更正
                end
            end 
        end
    end

    always @(posedge clk) begin
        if(rst) begin
            out_buzy    <= 0;
            out_device  <= `DEVICE_JMP;
            out_value   <= 0;
        end
        else begin
            if(out_buzy) begin // 如果数据准备好了，将要输出
                if(!cdb_buzy && !dvc_adder_buzy && !dvc_logic_buzy && !dvc_memory_buzy) begin // 没人想抢占才不忙
                    out_buzy  <= 0;
                    out_value <= 0;
                end
            end
            else begin // 还没有准备好，试图从保留站输入
                if(buffer_buzy && buffer_ready) begin
                    case(buffer_algorithm)
                        `JMP_ALGO_BEQ: begin
                            out_buzy  <= (buffer_valueA[31:0] == buffer_valueB[31:0]); // 跳转不成功，则不上 CDB
                            out_value <= (buffer_valueA[31:0] == buffer_valueB[31:0]) ? buffer_targetAddr[31:0] : 0;
                        end
                        `JMP_ALGO_JMP: begin
                            out_buzy  <= 1;
                            out_value <= buffer_targetAddr[31:0];
                        end
                        //! default 保持不变
                    endcase
                end
            end
        end
    end
endmodule


// -------------------- 寄存器堆 -------------------- //
//! 读寄存器使用组合逻辑
//! 修改寄存器必须和指令发射同步完成，指令不发射，就不能修改寄存器
`define GPR_SIZE 32
module GPR (
    // 以下内容来自指令发射缓冲器
    input        in_buzy,
    input        in_write,
    input [4 :0] in_writeId,
    input [35:0] in_writeValue, // 这里的 writeValue 可能是指出设备，或者直接给出常量
    input [4 :0] in_readIdA,
    input [4 :0] in_readIdB, // 任何指令都必须读两个寄存器中的值

    input in_launch, //! 这一瞬间指令是否能够成功发射

    // 以下端口来自计算机基本结构
    input clk,
    input rst,

    // 以下内容来自 cdb
    input        cdb_buzy,
    input [2 :0] cdb_device,
    input [31:0] cdb_value,

    // 以下内容为输出
    output [35:0] out_readA,
    output [35:0] out_readB
);
    integer i;


    reg [35:0] registers [0 : `GPR_SIZE - 1]; // 寄存器数组
    always @(posedge clk) begin // 描述寄存器数组的写入行为
        if(rst) begin
            for(i = 0; i < `GPR_SIZE; i += 1) begin
                registers[i] <= {1'b1, 3'b000, 32'h00000000}; //! 初始化时，数据均为就绪的 0
            end
        end
        else begin
            for(i = 1; i < `GPR_SIZE; i += 1) begin // 监听 CDB, 0号寄存器不可以写
                if(in_launch && in_writeId == i) begin // 只有发射同时才能写寄存器
                    registers[in_writeId] <= in_writeValue; //! 此处一定要注意，此处绝对不能读 CDB
                    //! 就算这个时刻 CDB 上有对应元件输出的数据，也不能读，因为当前指令才刚发射
                end
                else begin // 此处一定要记得判断 cdb_buzy
                    if(!registers[i][35] && cdb_buzy && registers[i][34:32] == cdb_device) begin
                        registers[i][35]    <= 1;
                        registers[i][34:32] <= 0;
                        registers[i][31: 0] <= cdb_value;
                    end
                end
            end
        end
    end

    // 描述数据读取的行为，保证可以在 CDB 上读取数据
    FetchCDB U_FetchCDB_readA(
        .cdb_buzy  (cdb_buzy  ),
        .cdb_device(cdb_device),
        .cdb_value (cdb_value ),
        .buffer_value   (registers[in_readIdA]),
        .buffer_newValue(out_readA)
    );
    FetchCDB U_FetchCDB_readB(
        .cdb_buzy  (cdb_buzy  ),
        .cdb_device(cdb_device),
        .cdb_value (cdb_value ),
        .buffer_value   (registers[in_readIdB]),
        .buffer_newValue(out_readB)
    );
endmodule


// -------------------- 取指令模块-------------------- //
//! 注：PC 也要监听 CDB 中设备 DEVICE_JMP 的输出
//! jumpState: 有指令在缓冲，JMP模块在工作，CDB 上在发送 JMP 的结果
//! 换言之，PC 会保持在 跳转指令的下一条指令处，原指令缓冲器保持在无效状态
`define IFU_PC_CS 32'h00003000
`define IFU_SIZE  1024
module IFU (
    // 以下端口来自 CDB
    input        cdb_buzy,
    input [2 :0] cdb_device,
    input [31:0] cdb_value,

    // 以下端口来自控制器 //! 注意：除此之外还需要额外判断 指令寄存器 ir 为空
    input ctrl_readIns, //! ctrl_readIns = 指令缓冲器空 && JMP模块不工作 && CDB输出设备不是IFU

    // 以下端口来自计算机基本结构
    input clk,
    input rst,

    // 以下端口来自后继设备 指令缓冲器
    input nxt_buzy,

    // 以下端口为输出
    output reg[31:0] pc, // 下一条指令地址
    output reg       ir_buzy,
    output reg[31:0] ir // 当前指令的内容
);
    reg [31:0] instructions [0 : `IFU_SIZE - 1]; // 指令 ROM
    initial begin
        $readmemh("code.txt", instructions, 0, `IFU_SIZE - 1); // 从 code.txt 读取数据
    end

    always @(posedge clk) begin // PC 的寄存器逻辑
        if(rst) pc <= `IFU_PC_CS; //? 代码段起始地址
        else begin
            if(cdb_buzy && cdb_device == `DEVICE_JMP) begin // PC 要从 CDB 监听 JMP 模块的数据
                pc <= cdb_value;
            end
            else begin
                if(!ir_buzy && ctrl_readIns) pc <= pc + 4; // 可以取下一条指令
            end
        end
    end

    always @(posedge clk) begin // ir_buzy 与 ir 的逻辑
        if(rst) begin
            ir_buzy <= 0;
            ir      <= 0;
        end
        else begin
            if(ir_buzy) begin
                if(!nxt_buzy) begin // 如果后继设备（指令缓冲寄存器）不忙
                    ir_buzy <= 0;
                    ir      <= 0;
                end
            end
            else begin // 如果当前指令缓冲寄存器里什么都没有
                if(ctrl_readIns) begin // 如果可以读取指令
                    ir_buzy <= 1;
                    ir      <= instructions[pc - `IFU_PC_CS];
                end
            end
        end
    end
endmodule


// -------------------- MIPS-Lite3 指令集 -------------------- //
`define FUNC_ADDU      (6'b100001)    // MIPS-Lite3
`define FUNC_SLT       (6'b101010)
`define FUNC_SUBU      (6'b100011)
`define FUNC_JR        (6'b001000)

`define OP_ADDI        (6'b001000)    // MIPS-Lite3 SPECIAL
`define OP_ADDIU       (6'b001001)
`define OP_BEQ         (6'b000100)
`define OP_J           (6'b000010)
`define OP_JAL         (6'b000011)
`define OP_LUI         (6'b001111)
`define OP_LW          (6'b100011)
`define OP_SPECIAL     (6'b000000)
`define OP_SW          (6'b101011)
`define OP_ORI         (6'b001101)


// -------------------- 译码读数电路(控制器) -------------------- //
//! 译码读数电路的输出寄存器是指令发射缓冲寄存器
//! Ctrl 里面包含了一个 GPR
module Ctrl (
    // 以下端口来自 CDB
    input        cdb_buzy,
    input [2 :0] cdb_device,
    input [31:0] cdb_value,

    // 以下端口来自前驱设备
    input        ir_buzy,
    input [31:0] ir,

    // 以下端口来自计算机基本结构
    input clk,
    input rst,

    // 以下端口来自后继设备，译码器需要通过判断后继设备是否忙从而决定指令能否发射
    input nxt_adder_buzy,
    input nxt_logic_buzy,
    input nxt_dm_buzy   ,
    input nxt_jmp_buzy  , //! 请注意，这里的 buzy 不只是 BufferIn，而是 BufferIn || BufferOut

    // 以下端口为输出的所有控制信号
    output reg        out_buzy, //! 发射前一定要判断能够发射
    output reg        out_device,

    output reg [1 :0] out_algorithm,
    output reg [35:0] out_valueA,
    output reg [35:0] out_valueB,
    output reg        out_dm_write,
    output reg        out_dm_sign,
    output reg [15:0] out_dm_offset, // 带 dm 的输出位只会被送给输入输出缓冲站
    output reg [35:0] out_targetAddr  //! 要么是某个寄存器的值，要么可以通过 PC+4 与常量算出
);
    wire dvc_avai[0:7]; // 用于检查设备是否可用
    assign dvc_avai[0] = 0; //! 不允许使用零号设备
    assign dvc_avai[`DEVICE_ADDER] = nxt_adder_buzy;
    assign dvc_avai[`DEVICE_LOGIC] = nxt_logic_buzy;
    assign dvc_avai[`DEVICE_DM   ] = nxt_dm_buzy   ;
    assign dvc_avai[4            ] = 0;
    assign dvc_avai[5            ] = 0;
    assign dvc_avai[6            ] = 0;
    assign dvc_avai[`DEVICE_JMP  ] = nxt_jmp_buzy  ;

    //! 这五个端口输出到 GPR, 要记得给这五个端口赋值
    reg        out_reg_write;      // 是否需要写寄存器
    reg [4 :0] out_reg_writeId;    // 写哪个寄存器
    reg [35:0] out_reg_writeValue; // 向寄存器里写什么, //! 这里的 writeValue 可能是指出设备，或者直接给出常量
    reg [4 :0] out_reg_readIdA;
    reg [4 :0] out_reg_readIdB;

    wire   nxt_buzy;
    assign nxt_buzy = dvc_avai[out_device]; // 将要输出到的设备是否在忙

    wire [35:0] reg_readA; // 寄存器读到的数据
    wire [35:0] reg_readB;

    GPR U_GPR( // 从逻辑上讲，GPR 在指令缓冲寄存器的后面
        .in_buzy      (out_buzy          ),
        .in_write     (out_reg_write     ),
        .in_writeId   (out_reg_writeId   ),
        .in_writeValue(out_reg_writeValue), 
        .in_readIdA   (out_reg_readIdA   ),
        .in_readIdB   (out_reg_readIdB   ), // 任何指令都必须读两个寄存器中的值

        .in_launch(out_buzy && !nxt_buzy), //! 这一瞬间指令是否能够成功发射

        // 以下端口来自计算机基本结构
        .clk(clk),
        .rst(rst),

        // 以下内容来自 cdb
        .cdb_buzy  (cdb_buzy  ),
        .cdb_device(cdb_device),
        .cdb_value (cdb_value ),

        // 以下内容为输出 //! 目前我认为，此处输出不需要检查 CDB //! 好了现在我不这么认为了
        .out_readA(reg_readA),
        .out_readB(reg_readB) //! 已经改为走 CDB，把查 CDB 写到 Ctrl 里太乱了
    );

    wire [5:0] instr; assign instr = ir[31:26]; // 指令名称 OP
    wire [5:0] func ; assign func  = ir[5 : 0]; // special 指令函数名称

    wire [15:0] imm16; assign imm16 = ir[15:0]; // 16 位立即数
    wire [15:0] imm26; assign imm26 = ir[25:0]; // 26 位立即数

    wire [4:0] rs; assign rs = ir[25:21]; // 寄存器编号
    wire [4:0] rt; assign rt = ir[20:16];
    wire [4:0] rd; assign rd = ir[15:11];

    always @(posedge clk) begin
        if(rst) begin
            out_buzy       <= 0;
            out_device     <= 0; //! 这就是为什么不允许使用零号设备
            out_algorithm  <= 0;
            out_algorithm  <= 0;
            out_dm_write   <= 0;
            out_dm_sign    <= 0;
            out_dm_offset  <= 0;
            out_targetAddr <= 0;
            out_valueA     <= 0;
            out_valueB     <= 0;

            // 送到寄存器堆的数据
            out_reg_write      <= 0;
            out_reg_writeId    <= 0;
            out_reg_writeValue <= 0;
            out_reg_readIdA    <= 0;
            out_reg_readIdB    <= 0;
        end
        else begin
            if(out_buzy) begin // 如果当前设备中有数据，尝试向后继设备输出
                if(!nxt_buzy) begin // 清空所有寄存器即可
                    out_buzy           <= 0;
                    out_device         <= 0;
                    out_algorithm      <= 0;
                    out_dm_write       <= 0;
                    out_dm_sign        <= 0;
                    out_dm_offset      <= 0;
                    out_targetAddr     <= 0;
                    out_valueA         <= 0;
                    out_valueB         <= 0;
                    out_reg_write      <= 0;
                    out_reg_writeId    <= 0;
                    out_reg_writeValue <= 0;
                    out_reg_readIdA    <= 0;
                    out_reg_readIdB    <= 0;
                end
            end
            else begin // 如果指令缓冲寄存器当前没有数据，尝试从 ir 读入
                if(ir_buzy) begin
                    //! -------------------- 在此处进行指令译码 -------------------- !//
                    case(instr)
                        `OP_ADDI: begin
                            out_buzy           <= 1;
                            out_device         <= `DEVICE_ADDER;
                            out_algorithm      <= `ADDER_ALGO_ADD;
                            out_dm_write       <= 0;
                            out_dm_sign        <= 0;
                            out_dm_offset      <= 0;
                            out_targetAddr     <= 0;
                            out_valueA         <= reg_readA;
                            out_valueB         <= {{16{imm16[15]}}, imm16}; // 按符号拓展 imm16
                            out_reg_write      <= 1; // 需要写寄存器
                            out_reg_writeId    <= rt; // rt = rs + sign(imm16)
                            out_reg_writeValue <= {1'b0, `DEVICE_ADDER, 32'h00000000};
                            out_reg_readIdA    <= rs;
                            out_reg_readIdB    <= 0;
                        end
                        /*
                        OP_ADDIU   :
                        OP_BEQ     :
                        OP_J       :
                        OP_JAL     :
                        OP_LUI     :
                        OP_LW      :
                        OP_SPECIAL :
                        OP_SW      :
                        OP_ORI     :*/
                    endcase
                end
            end
        end
    end
endmodule


//! -------------------- 以下内容尚未完成 -------------------- //
// MIPS 总电路图
// testbench 激励文件
