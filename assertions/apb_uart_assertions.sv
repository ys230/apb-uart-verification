module apb_uart_assertions (
    input logic        PCLK,
    input logic        PRESETn,
    input logic        PSEL,
    input logic        PENABLE,
    input logic        PREADY,
    input logic        PSLVERR,
    input logic        tx_fifo_push,
    input logic        rx_fifo_pop,
    input logic        tx_enable,
    input logic        rx_enable,
    input logic [31:0] scratch,
    input logic [15:0] baud_div
);
    timeunit 1ns;
    timeprecision 1ps;

    // A reset pulse between clock edges cancels checks that span two edges.
    logic assertions_active;
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) assertions_active <= 1'b0;
        else assertions_active <= 1'b1;
    end

    ap_ready_only_in_access: assert property (
        @(posedge PCLK)
        (assertions_active && PREADY) |-> (PSEL && PENABLE)
    ) else $error("PREADY asserted outside APB access");

    ap_error_only_on_completion: assert property (
        @(posedge PCLK)
        (assertions_active && PSLVERR) |-> PREADY
    ) else $error("PSLVERR asserted without APB completion");

    ap_error_has_no_fifo_command: assert property (
        @(posedge PCLK)
        (assertions_active && PSLVERR) |-> !(tx_fifo_push || rx_fifo_pop)
    ) else $error("APB error caused a TX push or RX pop");

    ap_one_completion_per_setup: assert property (
        @(posedge PCLK)
        (assertions_active && PREADY) |=> (!assertions_active || !PREADY)
    ) else $error("PREADY remained high after a completed transfer");

    ap_error_preserves_control_state: assert property (
        @(posedge PCLK)
        (assertions_active && PSLVERR) |=>
            (!assertions_active || $stable({tx_enable, rx_enable, scratch, baud_div}))
    ) else $error("APB error changed CTRL, SCRATCH, or BAUD_DIV");
endmodule

bind apb_uart apb_uart_assertions u_apb_uart_assertions (
    .PCLK(PCLK),
    .PRESETn(PRESETn),
    .PSEL(PSEL),
    .PENABLE(PENABLE),
    .PREADY(PREADY),
    .PSLVERR(PSLVERR),
    .tx_fifo_push(tx_fifo_push),
    .rx_fifo_pop(rx_fifo_pop),
    .tx_enable(tx_enable),
    .rx_enable(rx_enable),
    .scratch(scratch),
    .baud_div(baud_div)
);
