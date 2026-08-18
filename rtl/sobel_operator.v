`timescale 1ns/1ps

// Pure combinational 3x3 Sobel operator.
//
// Pixel layout:
//   p00 p01 p02
//   p10 p11 p12
//   p20 p21 p22
//
// The hardware-friendly magnitude is |Gx| + |Gy|.  Values above 255 are
// saturated so the result remains an unsigned 8-bit pixel.
module sobel_operator (
    input  wire [7:0] p00,
    input  wire [7:0] p01,
    input  wire [7:0] p02,
    input  wire [7:0] p10,
    input  wire [7:0] p11,
    input  wire [7:0] p12,
    input  wire [7:0] p20,
    input  wire [7:0] p21,
    input  wire [7:0] p22,
    output wire [7:0] edge_out
);

    // Each positive/negative half of a Sobel axis is at most 4*255=1020.
    wire [10:0] gx_positive;
    wire [10:0] gx_negative;
    wire [10:0] gy_positive;
    wire [10:0] gy_negative;

    wire signed [11:0] gx_signed;
    wire signed [11:0] gy_signed;
    wire        [11:0] gx_abs;
    wire        [11:0] gy_abs;
    wire        [12:0] magnitude;

    // Gx = (right column) - (left column)
    assign gx_positive = {3'b000, p02}
                       + ({3'b000, p12} << 1)
                       + {3'b000, p22};
    assign gx_negative = {3'b000, p00}
                       + ({3'b000, p10} << 1)
                       + {3'b000, p20};

    // Gy = (bottom row) - (top row)
    assign gy_positive = {3'b000, p20}
                       + ({3'b000, p21} << 1)
                       + {3'b000, p22};
    assign gy_negative = {3'b000, p00}
                       + ({3'b000, p01} << 1)
                       + {3'b000, p02};

    assign gx_signed = $signed({1'b0, gx_positive})
                     - $signed({1'b0, gx_negative});
    assign gy_signed = $signed({1'b0, gy_positive})
                     - $signed({1'b0, gy_negative});

    assign gx_abs = gx_signed[11] ? (~gx_signed + 12'd1) : gx_signed;
    assign gy_abs = gy_signed[11] ? (~gy_signed + 12'd1) : gy_signed;
    assign magnitude = {1'b0, gx_abs} + {1'b0, gy_abs};

    assign edge_out = (magnitude > 13'd255) ? 8'hff : magnitude[7:0];

    // p11 has a zero coefficient in both Sobel kernels.  It remains an input
    // so that the 3x3 window mapping is explicit and easy to inspect.
    wire _unused_p11 = ^p11;

endmodule

