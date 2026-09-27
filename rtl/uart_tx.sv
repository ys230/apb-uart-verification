module uart_tx (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    input  logic [15:0] baud_div,
    input  logic        fifo_empty,
    input  logic [7:0]  fifo_data,
    output logic        fifo_pop,
    output logic        tx,
    output logic        busy
);
    timeunit 1ns;
    timeprecision 1ps;

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t state;
    logic [15:0] ticks_left;
    logic [15:0] frame_div;
    logic [7:0] frame_data;
    logic [2:0] bit_idx;

    assign busy = (state != IDLE);
    assign fifo_pop = rst_n && enable && (state == IDLE) && !fifo_empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            ticks_left <= '0;
            frame_div <= '0;
            frame_data <= '0;
            bit_idx <= '0;
            tx <= 1'b1;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (fifo_pop) begin
                        frame_data <= fifo_data;
                        frame_div <= baud_div;
                        ticks_left <= baud_div;
                        bit_idx <= '0;
                        tx <= 1'b0;
                        state <= START;
                    end
                end
                START: begin
                    if (ticks_left == 16'd1) begin
                        tx <= frame_data[0];
                        ticks_left <= frame_div;
                        state <= DATA;
                    end else begin
                        ticks_left <= ticks_left - 1'b1;
                    end
                end
                DATA: begin
                    if (ticks_left == 16'd1) begin
                        ticks_left <= frame_div;
                        if (bit_idx == 3'd7) begin
                            tx <= 1'b1;
                            state <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                            tx <= frame_data[bit_idx + 3'd1];
                        end
                    end else begin
                        ticks_left <= ticks_left - 1'b1;
                    end
                end
                STOP: begin
                    if (ticks_left == 16'd1) begin
                        tx <= 1'b1;
                        state <= IDLE;
                    end else begin
                        ticks_left <= ticks_left - 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
