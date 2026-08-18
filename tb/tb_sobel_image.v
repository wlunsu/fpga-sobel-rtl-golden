`timescale 1ns/1ps

module tb_sobel_image;

    parameter integer IMAGE_WIDTH  = 64;
    parameter integer IMAGE_HEIGHT = 64;
    localparam integer FRAME_PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT;

    reg clk;
    reg rst;
    reg frame_start;
    reg [7:0] pixel_in;
    reg pixel_in_valid;

    wire [7:0] pixel_out;
    wire pixel_out_valid;
    wire frame_done;
    wire busy;

    reg [7:0] image_memory [0:FRAME_PIXELS-1];
    reg [8*512-1:0] input_filename;
    reg [8*512-1:0] output_filename;
    reg [8*128-1:0] case_name;

    integer output_file;
    integer input_index;
    integer output_count;
    integer timeout_cycles;
    integer simulation_finished;

    sobel_stream_core #(
        .IMAGE_WIDTH(IMAGE_WIDTH),
        .IMAGE_HEIGHT(IMAGE_HEIGHT)
    ) dut (
        .clk(clk),
        .rst(rst),
        .frame_start(frame_start),
        .pixel_in(pixel_in),
        .pixel_in_valid(pixel_in_valid),
        .pixel_out(pixel_out),
        .pixel_out_valid(pixel_out_valid),
        .frame_done(frame_done),
        .busy(busy)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        if (!$value$plusargs("INPUT_MEM=%s", input_filename))
            input_filename = "input.mem";
        if (!$value$plusargs("OUTPUT_MEM=%s", output_filename))
            output_filename = "rtl_output.mem";
        if (!$value$plusargs("CASE_NAME=%s", case_name))
            case_name = "unnamed";

        $display("TB case       : %0s", case_name);
        $display("TB input file : %0s", input_filename);
        $display("TB output file: %0s", output_filename);
        $display("TB dimensions : %0d x %0d", IMAGE_WIDTH, IMAGE_HEIGHT);

        $readmemh(input_filename, image_memory);
        output_file = $fopen(output_filename, "w");
        if (output_file == 0) begin
            $display("TB ERROR: could not open output file.");
            $finish;
        end

        rst                 = 1'b1;
        frame_start         = 1'b0;
        pixel_in            = 8'h00;
        pixel_in_valid      = 1'b0;
        output_count        = 0;
        timeout_cycles      = 0;
        simulation_finished = 0;

        repeat (5) @(negedge clk);
        rst = 1'b0;

        // frame_start is deliberately one clock before the first valid pixel.
        @(negedge clk);
        frame_start = 1'b1;
        @(negedge clk);
        frame_start = 1'b0;

        for (input_index = 0; input_index < FRAME_PIXELS; input_index = input_index + 1) begin
            pixel_in       = image_memory[input_index];
            pixel_in_valid = 1'b1;
            @(negedge clk);
        end
        pixel_in_valid = 1'b0;
        pixel_in       = 8'h00;

        wait (simulation_finished == 1);
        repeat (2) @(negedge clk);
        $fclose(output_file);

        if (output_count == FRAME_PIXELS)
            $display("TB PASS: wrote exactly %0d output pixels.", output_count);
        else
            $display("TB FAIL: expected %0d output pixels, got %0d.", FRAME_PIXELS, output_count);

        $finish;
    end

    // Sample outputs after nonblocking assignments have settled.
    always @(posedge clk) begin
        #1;
        if (pixel_out_valid) begin
            $fwrite(output_file, "%02x\n", pixel_out);
            output_count = output_count + 1;
        end
        if (frame_done)
            simulation_finished = 1;
    end

    // Protect batch runs from hanging on an interface/timing error.
    always @(posedge clk) begin
        if (!rst) begin
            timeout_cycles = timeout_cycles + 1;
            if (timeout_cycles > (FRAME_PIXELS * 4 + 1000)) begin
                $display("TB FAIL: timeout waiting for frame_done.");
                $fclose(output_file);
                $finish;
            end
        end
    end

endmodule

