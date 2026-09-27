module sync_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  push,
    input  logic [DATA_WIDTH-1:0] push_data,
    input  logic                  pop,
    output logic [DATA_WIDTH-1:0] front_data,
    output logic                  full,
    output logic                  empty
);
    timeunit 1ns;
    timeprecision 1ps;

    localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int COUNT_W = $clog2(DEPTH + 1);

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    logic [PTR_W-1:0] wr_ptr;
    logic [PTR_W-1:0] rd_ptr;
    logic [COUNT_W-1:0] count;
    logic push_fire;
    logic pop_fire;

    function automatic logic [PTR_W-1:0] next_ptr(input logic [PTR_W-1:0] ptr);
        if (ptr == PTR_W'(DEPTH - 1)) begin
            return '0;
        end
        return ptr + 1'b1;
    endfunction

    assign full = (count == COUNT_W'(DEPTH));
    assign empty = (count == '0);
    assign front_data = empty ? '0 : mem[rd_ptr];
    assign push_fire = push && !full;
    assign pop_fire = pop && !empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count <= '0;
        end else begin
            if (push_fire) begin
                mem[wr_ptr] <= push_data;
                wr_ptr <= next_ptr(wr_ptr);
            end
            if (pop_fire) begin
                rd_ptr <= next_ptr(rd_ptr);
            end
            case ({push_fire, pop_fire})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
