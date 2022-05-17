// -------------------- 基于 Tomasulo 算法 和 流水线 的 MIPS-Lite4 处理器设计 -------------------- //
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


`timescale 1ns/10ps


// -------------------- 所有执行部件以及其编号 -------------------- //
`define DEVICE_ADDER 1 // 加减运算器
`define DEVICE_LOGIC 2 // 逻辑运算器
`define DEVICE_DM    3 // 数据存储器
`define DEVICE_JMP   7 // 跳转元件


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
    input[2 :0] cbd_device,  // CDB 的输出设备
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
                        if(!out_valueA[35] && out_valueA[34:32] == cbd_device) begin //! 监听数据 A
                            out_valueA[35]    <= 1;
                            out_valueA[34:32] <= 0;
                            out_valueA[31: 0] <= cdb_value;
                        end
                        if(!out_valueB[35] && out_valueB[34:32] == cbd_device) begin //! 监听数据 B
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
                    out_valueA    <= in_valueA;
                    out_valueB    <= in_valueB;
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
    // 以下五个端口来自逻辑缓冲站
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
    input[15:0] in_DM_offset,    // 地址偏移量 (需要带符号拓展)
    
    // 以下三个端口数据来自 CDB(通用数据总线) //! 输入输出缓冲站也需要等待 CDB 中的数据
    input       cdb_buzy,
    input[2 :0] cbd_device,
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

    wire buffer_ready;
    assign buffer_ready = buffer_DM_write ? buffer_valueA[35] && buffer_valueB[35] : buffer_valueA[35];
    //! 写内存时要求两个值都需要就绪，读内存时第二个值没有意义

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
                    if(!buffer_valueA[35] && cbd_device == buffer_valueA[34:32]) begin // 可以读入数据 A
                        buffer_valueA[35]    <= 1;
                        buffer_valueA[34:32] <= 0;
                        buffer_valueA[31: 0] <= cdb_value;
                    end
                    if(buffer_DM_write && !buffer_valueB[35] && cbd_device == buffer_valueB[34:32]) begin // 可以读入数据 B
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
                    buffer_valueA    <= in_valueA;
                    buffer_valueB    <= in_valueB;
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
                            out_value <= {{24{buffer_DM_sign ? DM[buffer_addr + 1][7] : 1'b0}}, DM[buffer_addr + 1], DM[buffer_addr + 0]};
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


//! -------------------- 以下内容尚未完成 -------------------- //
// 跳转器
// 寄存器堆

// 取指令模块    //! 注：PC 也要监听 CDB 中设备 DEVICE_JMP 的输出
//! 取指令模块中有 jumpState 状态位，用于控制流水线阻塞（锁 PC 和 原指令缓冲器）
//! DEVICE_JMP 上 CDB 的同时，清 jumpState 状态
//! 换言之，PC 会保持在 跳转指令的下一条指令处，原指令缓冲器保持在无效状态

// MIPS 总电路图