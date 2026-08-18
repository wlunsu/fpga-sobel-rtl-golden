`timescale 1ns/1ps

// Streaming 8-bit grayscale Sobel core.
//
// Protocol:
//   1. Pulse frame_start for one clock while pixel_in_valid is low.
//   2. Send IMAGE_WIDTH*IMAGE_HEIGHT pixels in row-major order.
//   3. pixel_in_valid may pause; there is no ready/backpressure signal.
//   4. The core emits exactly one output pixel per input pixel, delayed by
//      IMAGE_WIDTH+1 accepted pixels, followed by an internal border flush.
//   5. frame_done is asserted with the last valid output pixel.
//
// The two line arrays are synthesizable line buffers.  Their asynchronous read
// style favours simple learning and simulation; a Red Pitaya wrapper may later
// replace them with synchronous BRAM without changing the Sobel operator.
module sobel_stream_core #(
    parameter integer IMAGE_WIDTH  = 64,
    parameter integer IMAGE_HEIGHT = 64
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       frame_start,
    input  wire [7:0] pixel_in,
    input  wire       pixel_in_valid,

    output reg  [7:0] pixel_out,
    output reg        pixel_out_valid,
    output reg        frame_done,
    output reg        busy
);

    function integer clog2;
        input integer value;
        integer work;
        begin
            work = value - 1;
            clog2 = 0;
            while (work > 0) begin
                clog2 = clog2 + 1;
                work = work >> 1;
            end
        end
    endfunction

    localparam integer FRAME_PIXELS    = IMAGE_WIDTH * IMAGE_HEIGHT;
    localparam integer PIPE_DELAY      = IMAGE_WIDTH + 1;
    localparam integer COL_WIDTH       = (IMAGE_WIDTH  <= 2) ? 1 : clog2(IMAGE_WIDTH);
    localparam integer ROW_WIDTH       = (IMAGE_HEIGHT <= 2) ? 1 : clog2(IMAGE_HEIGHT);
    localparam integer COUNT_WIDTH     = (FRAME_PIXELS <= 2) ? 1 : clog2(FRAME_PIXELS + 1);
    localparam integer FLUSH_WIDTH     = (PIPE_DELAY   <= 2) ? 1 : clog2(PIPE_DELAY + 1);

    reg [7:0] line_previous  [0:IMAGE_WIDTH-1];
    reg [7:0] line_two_back  [0:IMAGE_WIDTH-1];

    reg [COL_WIDTH-1:0] input_col;
    reg [ROW_WIDTH-1:0] input_row;
    reg [COL_WIDTH-1:0] output_col;
    reg [ROW_WIDTH-1:0] output_row;
    reg [COUNT_WIDTH-1:0] input_count;
    reg [FLUSH_WIDTH-1:0] flush_remaining;
    reg flushing;

    // Last two pixels from each of the three rows in the active window.
    reg [7:0] top_left;
    reg [7:0] top_middle;
    reg [7:0] middle_left;
    reg [7:0] middle_middle;
    reg [7:0] bottom_left;
    reg [7:0] bottom_middle;

    wire [7:0] top_right    = line_two_back[input_col];
    wire [7:0] middle_right = line_previous[input_col];
    wire [7:0] sobel_value;

    sobel_operator u_sobel_operator (
        .p00(top_left),
        .p01(top_middle),
        .p02(top_right),
        .p10(middle_left),
        .p11(middle_middle),
        .p12(middle_right),
        .p20(bottom_left),
        .p21(bottom_middle),
        .p22(pixel_in),
        .edge_out(sobel_value)
    );

    initial begin
        if ((IMAGE_WIDTH < 3) || (IMAGE_HEIGHT < 3)) begin
            $display("ERROR: Sobel image dimensions must both be at least 3.");
            $finish;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            pixel_out       <= 8'h00;
            pixel_out_valid <= 1'b0;
            frame_done      <= 1'b0;
            busy            <= 1'b0;
            flushing        <= 1'b0;
            input_col       <= {COL_WIDTH{1'b0}};
            input_row       <= {ROW_WIDTH{1'b0}};
            output_col      <= {COL_WIDTH{1'b0}};
            output_row      <= {ROW_WIDTH{1'b0}};
            input_count     <= {COUNT_WIDTH{1'b0}};
            flush_remaining <= {FLUSH_WIDTH{1'b0}};
            top_left        <= 8'h00;
            top_middle      <= 8'h00;
            middle_left     <= 8'h00;
            middle_middle   <= 8'h00;
            bottom_left     <= 8'h00;
            bottom_middle   <= 8'h00;
        end else begin
            pixel_out_valid <= 1'b0;
            frame_done      <= 1'b0;

            if (frame_start) begin
                // The line memories need not be cleared: the first two rows of
                // the new frame overwrite every location before it is used.
                busy            <= 1'b1;
                flushing        <= 1'b0;
                input_col       <= {COL_WIDTH{1'b0}};
                input_row       <= {ROW_WIDTH{1'b0}};
                output_col      <= {COL_WIDTH{1'b0}};
                output_row      <= {ROW_WIDTH{1'b0}};
                input_count     <= {COUNT_WIDTH{1'b0}};
                flush_remaining <= {FLUSH_WIDTH{1'b0}};
                top_left        <= 8'h00;
                top_middle      <= 8'h00;
                middle_left     <= 8'h00;
                middle_middle   <= 8'h00;
                bottom_left     <= 8'h00;
                bottom_middle   <= 8'h00;
            end else if (busy && !flushing && pixel_in_valid) begin
                // Read-before-write semantics provide pixels from the two
                // previous rows at the current column.
                line_two_back[input_col] <= line_previous[input_col];
                line_previous[input_col] <= pixel_in;

                // Once the window-centre delay has elapsed, the output stream
                // is in row-major order.  All four outer borders are forced to
                // zero; interior pixels use the active 3x3 window.
                if (input_count >= PIPE_DELAY) begin
                    pixel_out_valid <= 1'b1;
                    if ((output_row == 0)
                        || (output_row == IMAGE_HEIGHT - 1)
                        || (output_col == 0)
                        || (output_col == IMAGE_WIDTH - 1)) begin
                        pixel_out <= 8'h00;
                    end else begin
                        pixel_out <= sobel_value;
                    end

                    if (output_col == IMAGE_WIDTH - 1) begin
                        output_col <= {COL_WIDTH{1'b0}};
                        if (output_row < IMAGE_HEIGHT - 1)
                            output_row <= output_row + 1'b1;
                    end else begin
                        output_col <= output_col + 1'b1;
                    end
                end

                // Advance the three horizontal shift-register pairs.
                if (input_col == IMAGE_WIDTH - 1) begin
                    input_col     <= {COL_WIDTH{1'b0}};
                    if (input_row < IMAGE_HEIGHT - 1)
                        input_row <= input_row + 1'b1;
                    top_left      <= 8'h00;
                    top_middle    <= 8'h00;
                    middle_left   <= 8'h00;
                    middle_middle <= 8'h00;
                    bottom_left   <= 8'h00;
                    bottom_middle <= 8'h00;
                end else begin
                    input_col     <= input_col + 1'b1;
                    top_left      <= top_middle;
                    top_middle    <= top_right;
                    middle_left   <= middle_middle;
                    middle_middle <= middle_right;
                    bottom_left   <= bottom_middle;
                    bottom_middle <= pixel_in;
                end

                if (input_count == FRAME_PIXELS - 1) begin
                    // The un-emitted tail consists of the penultimate row's
                    // right border plus the complete bottom border.
                    flushing        <= 1'b1;
                    flush_remaining <= PIPE_DELAY;
                end else begin
                    input_count <= input_count + 1'b1;
                end
            end else if (busy && flushing) begin
                pixel_out       <= 8'h00;
                pixel_out_valid <= 1'b1;

                if (output_col == IMAGE_WIDTH - 1) begin
                    output_col <= {COL_WIDTH{1'b0}};
                    if (output_row < IMAGE_HEIGHT - 1)
                        output_row <= output_row + 1'b1;
                end else begin
                    output_col <= output_col + 1'b1;
                end

                if (flush_remaining == 1) begin
                    flush_remaining <= {FLUSH_WIDTH{1'b0}};
                    flushing        <= 1'b0;
                    busy            <= 1'b0;
                    frame_done      <= 1'b1;
                end else begin
                    flush_remaining <= flush_remaining - 1'b1;
                end
            end
        end
    end

endmodule

