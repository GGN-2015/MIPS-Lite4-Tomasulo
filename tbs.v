module tb_FetchCDB;
    reg         cdb_buzy       ;
    reg  [2 :0] cdb_device     ;
    reg  [31:0] cdb_value      ;
    reg  [35:0] buffer_value   ;
    wire [35:0] buffer_newValue;

    // 测试 FetchCDB 能否按照预期工作
    FetchCDB U_FetchCDB(
        .cdb_buzy        (cdb_buzy       ),
        .cdb_device      (cdb_device     ),
        .cdb_value       (cdb_value      ),
        .buffer_value    (buffer_value   ),
        .buffer_newValue (buffer_newValue)
    );

    // 输出波形
    // initial begin
    //     $dumpfile("FetchCDB.vcd");
    //     $dumpvars(0, tb_FetchCDB);
    // end

    // 测试逻辑
    initial begin
        cdb_buzy     = 1;            // CDB 上 JMP 正在输出
        cdb_device   = `DEVICE_JMP ; //
        cdb_value    = 32'h12345678; // 输出 12345678H
        buffer_value = {1'b0, `DEVICE_ADDER, 32'h00000000}; // 未就绪，设备不是我的
        #20;
        buffer_value = {1'b0, `DEVICE_JMP, 32'h00000000};   // 未就绪，设备是我的
        #20;
        buffer_value = {1'b1, `DEVICE_JMP, 32'h87654321};   // 已就绪，设备是我的
        #20 $finish;
    end
endmodule


module tb_BufferIn; // 对 BufferIn 模块进行测试
    reg        in_hasInput ;
    reg [2 :0] in_device   ;
    reg [1 :0] in_algorithm;
    reg [35:0] in_valueA   ;
    reg [35:0] in_valueB   ;

    reg        cdb_buzy  ;
    reg [2 :0] cdb_device;
    reg [31:0] cdb_value ;

    reg clk, rst;
    reg nxt_buzy;

    wire        out_buzy     ;
    wire        out_ready    ;
    wire [1 :0] out_algorithm;
    wire [35:0] out_valueA   ;
    wire [35:0] out_valueB   ;

    //输出波形
    // initial begin
    //     $dumpfile("BufferIn.vcd");
    //     $dumpvars(0, tb_BufferIn);
    // end

    // 假设这是一个加法缓冲器
    BufferIn U_BufferIn(
        .in_hasInput  (in_hasInput ),
        .in_device    (in_device   ),
        .in_algorithm (in_algorithm),
        .in_valueA    (in_valueA   ),
        .in_valueB    (in_valueB   ),

        .device_now(`DEVICE_ADDER),  //? 这个端口一定从常数输入
        
        .cdb_buzy  (cdb_buzy  ),
        .cdb_device(cdb_device),
        .cdb_value (cdb_value ),

        .clk(clk),
        .rst(rst),

        .nxt_buzy(nxt_buzy),

        .out_buzy     (out_buzy     ),
        .out_ready    (out_ready    ),
        .out_algorithm(out_algorithm),
        .out_valueA   (out_valueA   ),
        .out_valueB   (out_valueB   )
    );

    initial clk = 0;
    always #1 clk = ~clk; // 设置时钟

    initial begin
        rst = 1;
        #2 rst = 0; // 清空
        #2;

        in_hasInput  = 1;
        in_device    = `DEVICE_LOGIC; // 不是输入到这个设备的
        in_algorithm = `ADDER_ALGO_ADD;
        in_valueA    = {1'b0, `DEVICE_DM, 32'd0};
        in_valueB    = {1'b1, 3'd0, 32'd12345678};

        cdb_buzy   = 0;
        cdb_device = `DEVICE_DM;
        cdb_value  = 87654321;

        nxt_buzy = 1; // 由于设备不对，什么都不做
        #2;
        in_device = `DEVICE_ADDER; // 设备改对后读入指令
        #2;
        in_hasInput = 0; // 等待一个周期
        #2;
        cdb_buzy = 1; // 读入就绪的数据
        #2;
        cdb_buzy = 0; // 等待一个周期
        #2;
        nxt_buzy = 0; // 可以输出后，清空数据
        #2;
        #2 $finish;
    end
endmodule
