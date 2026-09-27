module fpga_uart_demo #(
    // The board integration must supply the real input clock frequency.
    parameter int CLK_HZ = 0,
    parameter int BAUD_RATE = 115200,
    parameter int WAIT_CYCLES = 0,
    parameter int FIFO_DEPTH = 16
) (
    input  logic clk,
    input  logic reset_n,
    input  logic uart_rx,
    output logic uart_tx,
    output logic ready,
    output logic error
);
    timeunit 1ns;
    timeprecision 1ps;

    // Round to the closest integer number of clock cycles per UART bit.
    localparam int BAUD_DIV = (BAUD_RATE > 0)
        ? ((CLK_HZ + BAUD_RATE / 2) / BAUD_RATE) : 0;

    // Asynchronous assertion, two-clock synchronous release. No generated
    // clock is used. A board pushbutton may additionally need debouncing.
    (* ASYNC_REG = "TRUE" *) logic [1:0] reset_sync;
    logic core_reset_n;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) reset_sync <= 2'b00;
        else reset_sync <= {reset_sync[0], 1'b1};
    end
    assign core_reset_n = reset_sync[1];

    logic psel;
    logic penable;
    logic pwrite;
    logic [31:0] paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic pready;
    logic pslverr;

    apb_uart_echo_master #(.BAUD_DIV(BAUD_DIV)) u_master (
        .clk(clk), .rst_n(core_reset_n),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .prdata(prdata),
        .pready(pready), .pslverr(pslverr),
        .ready(ready), .error(error)
    );

    apb_uart #(.WAIT_CYCLES(WAIT_CYCLES), .FIFO_DEPTH(FIFO_DEPTH)) u_uart (
        .PCLK(clk), .PRESETn(core_reset_n),
        .PSEL(psel), .PENABLE(penable), .PWRITE(pwrite),
        .PADDR(paddr), .PWDATA(pwdata), .PRDATA(prdata),
        .PREADY(pready), .PSLVERR(pslverr),
        .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

`ifndef SYNTHESIS
    initial begin
        if (CLK_HZ <= 0 || BAUD_RATE <= 0 || BAUD_DIV < 4 || BAUD_DIV > 65535)
            $fatal(1, "Set CLK_HZ/BAUD_RATE so the rounded UART divisor is 4..65535");
        if (WAIT_CYCLES < 0 || FIFO_DEPTH < 1)
            $fatal(1, "WAIT_CYCLES must be >= 0 and FIFO_DEPTH must be >= 1");
    end
`endif
endmodule
