module uart_rx (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    input  logic [15:0] baud_div,
    input  logic        rx,
    output logic        valid,
    output logic [7:0]  data,
    output logic        framing_error,
    output logic        busy
);
    timeunit 1ns;
    timeprecision 1ps;

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;
    state_t state;
    logic rx_meta;
    logic rx_sync;
    logic rx_prev;
    logic [15:0] ticks_left;
    logic [15:0] frame_div;
    logic [7:0] shift_data;
    logic [2:0] bit_idx;

    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            rx_prev <= 1'b1;
            state <= IDLE;
            ticks_left <= '0;
            frame_div <= '0;
            shift_data <= '0;
            bit_idx <= '0;
            valid <= 1'b0;
            data <= '0;
            framing_error <= 1'b0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            rx_prev <= rx_sync;
            valid <= 1'b0;
            framing_error <= 1'b0;

            if (!enable) begin
                state <= IDLE;
                ticks_left <= '0;
            end else begin
                case (state)
                    IDLE: begin
                        if (rx_prev && !rx_sync) begin
                            frame_div <= baud_div;
                            ticks_left <= baud_div >> 1;
                            bit_idx <= '0;
                            state <= START;
                        end
                    end
                    START: begin
                        if (ticks_left == 16'd1) begin
                            if (!rx_sync) begin
                                ticks_left <= frame_div;
                                bit_idx <= '0;
                                state <= DATA;
                            end else begin
                                state <= IDLE;
                            end
                        end else begin
                            ticks_left <= ticks_left - 1'b1;
                        end
                    end
                    DATA: begin
                        if (ticks_left == 16'd1) begin
                            shift_data[bit_idx] <= rx_sync;
                            ticks_left <= frame_div;
                            if (bit_idx == 3'd7) begin
                                state <= STOP;
                            end else begin
                                bit_idx <= bit_idx + 1'b1;
                            end
                        end else begin
                            ticks_left <= ticks_left - 1'b1;
                        end
                    end
                    STOP: begin
                        if (ticks_left == 16'd1) begin
                            if (rx_sync) begin
                                data <= shift_data;
                                valid <= 1'b1;
                            end else begin
                                framing_error <= 1'b1;
                            end
                            state <= IDLE;
                        end else begin
                            ticks_left <= ticks_left - 1'b1;
                        end
                    end
                    default: state <= IDLE;
                endcase
            end
        end
    end
endmodule
