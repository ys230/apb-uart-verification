module apb_uart #(
    parameter int WAIT_CYCLES = 0,
    parameter int FIFO_DEPTH = 16
) (
    input  logic        PCLK,
    input  logic        PRESETn,
    input  logic        PSEL,
    input  logic        PENABLE,
    input  logic        PWRITE,
    input  logic [31:0] PADDR,
    input  logic [31:0] PWDATA,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    input  logic        uart_rx,
    output logic        uart_tx
);
    timeunit 1ns;
    timeprecision 1ps;

    localparam logic [31:0] ADDR_CTRL     = 32'h0000_0000;
    localparam logic [31:0] ADDR_STATUS   = 32'h0000_0004;
    localparam logic [31:0] ADDR_SCRATCH  = 32'h0000_0008;
    localparam logic [31:0] ADDR_BAUD_DIV = 32'h0000_000c;
    localparam logic [31:0] ADDR_TXDATA   = 32'h0000_0010;
    localparam logic [31:0] ADDR_RXDATA   = 32'h0000_0014;
    localparam int WAIT_W = (WAIT_CYCLES > 0) ? $clog2(WAIT_CYCLES + 1) : 1;

    logic [WAIT_W-1:0] wait_left;
    logic setup_seen;
    logic tx_enable;
    logic rx_enable;
    logic [31:0] scratch;
    logic [15:0] baud_div;
    logic rx_overflow_sticky;
    logic rx_framing_sticky;

    logic access_error;
    logic transfer_ok;
    logic apb_write;
    logic apb_read;
    logic ctrl_write;
    logic tx_runtime_enable;
    logic rx_runtime_enable;

    logic tx_full;
    logic tx_empty;
    logic [7:0] tx_front_data;
    logic tx_fifo_push;
    logic tx_fifo_pop;
    logic tx_busy;

    logic rx_full;
    logic rx_empty;
    logic [7:0] rx_front_data;
    logic rx_fifo_push;
    logic rx_fifo_pop;
    logic rx_busy;
    logic rx_valid;
    logic [7:0] rx_data;
    logic rx_framing_error;

    // SETUP reloads the wait count, including back-to-back transfers with PSEL high.
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            wait_left <= '0;
            setup_seen <= 1'b0;
        end else if (!PSEL) begin
            wait_left <= '0;
            setup_seen <= 1'b0;
        end else if (!PENABLE) begin
            wait_left <= WAIT_W'(WAIT_CYCLES);
            setup_seen <= 1'b1;
        end else if (wait_left != '0) begin
            wait_left <= wait_left - 1'b1;
        end else if (PREADY) begin
            setup_seen <= 1'b0;
        end
    end

    assign PREADY = PRESETn && PSEL && PENABLE && setup_seen &&
                    (wait_left == '0);

    // Every invalid access returns an error without changing an APB-controlled state.
    always_comb begin
        access_error = 1'b0;
        case (PADDR)
            ADDR_CTRL: begin
            end
            ADDR_STATUS: begin
                access_error = PWRITE;
            end
            ADDR_SCRATCH: begin
            end
            ADDR_BAUD_DIV: begin
                if (PWRITE && (tx_busy || rx_busy ||
                               (PWDATA[31:16] != 16'd0) ||
                               (PWDATA[15:0] < 16'd4))) begin
                    access_error = 1'b1;
                end
            end
            ADDR_TXDATA: begin
                access_error = !PWRITE || tx_full;
            end
            ADDR_RXDATA: begin
                access_error = PWRITE || rx_empty;
            end
            default: access_error = 1'b1;
        endcase
    end

    assign PSLVERR = PREADY && access_error;
    assign transfer_ok = PREADY && !access_error;
    assign apb_write = transfer_ok && PWRITE;
    assign apb_read = transfer_ok && !PWRITE;
    assign ctrl_write = apb_write && (PADDR == ADDR_CTRL);

    // A disable write takes effect on its completion edge, including a pending TX launch.
    assign tx_runtime_enable = tx_enable && !(ctrl_write && !PWDATA[0]);
    assign rx_runtime_enable = rx_enable && !(ctrl_write && !PWDATA[1]);

    assign tx_fifo_push = apb_write && (PADDR == ADDR_TXDATA);
    assign rx_fifo_pop = apb_read && (PADDR == ADDR_RXDATA);
    assign rx_fifo_push = rx_valid;

    always_comb begin
        PRDATA = '0;
        if (apb_read) begin
            case (PADDR)
                ADDR_CTRL: PRDATA = {30'd0, rx_enable, tx_enable};
                ADDR_STATUS: PRDATA = {26'd0, rx_framing_sticky,
                                       rx_overflow_sticky, rx_full,
                                       rx_empty, tx_busy, tx_full};
                ADDR_SCRATCH: PRDATA = scratch;
                ADDR_BAUD_DIV: PRDATA = {16'd0, baud_div};
                ADDR_RXDATA: PRDATA = {24'd0, rx_front_data};
                default: PRDATA = '0;
            endcase
        end
    end

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            tx_enable <= 1'b0;
            rx_enable <= 1'b0;
            scratch <= '0;
            baud_div <= 16'd16;
            rx_overflow_sticky <= 1'b0;
            rx_framing_sticky <= 1'b0;
        end else begin
            if (apb_write) begin
                case (PADDR)
                    ADDR_CTRL: begin
                        tx_enable <= PWDATA[0];
                        rx_enable <= PWDATA[1];
                    end
                    ADDR_SCRATCH: scratch <= PWDATA;
                    ADDR_BAUD_DIV: baud_div <= PWDATA[15:0];
                    default: begin
                    end
                endcase
            end
            if (rx_valid && rx_full) begin
                rx_overflow_sticky <= 1'b1;
            end
            if (rx_framing_error) begin
                rx_framing_sticky <= 1'b1;
            end
        end
    end

    sync_fifo #(.DATA_WIDTH(8), .DEPTH(FIFO_DEPTH)) u_tx_fifo (
        .clk(PCLK),
        .rst_n(PRESETn),
        .push(tx_fifo_push),
        .push_data(PWDATA[7:0]),
        .pop(tx_fifo_pop),
        .front_data(tx_front_data),
        .full(tx_full),
        .empty(tx_empty)
    );

    uart_tx u_uart_tx (
        .clk(PCLK),
        .rst_n(PRESETn),
        .enable(tx_runtime_enable),
        .baud_div(baud_div),
        .fifo_empty(tx_empty),
        .fifo_data(tx_front_data),
        .fifo_pop(tx_fifo_pop),
        .tx(uart_tx),
        .busy(tx_busy)
    );

    uart_rx u_uart_rx (
        .clk(PCLK),
        .rst_n(PRESETn),
        .enable(rx_runtime_enable),
        .baud_div(baud_div),
        .rx(uart_rx),
        .valid(rx_valid),
        .data(rx_data),
        .framing_error(rx_framing_error),
        .busy(rx_busy)
    );

    sync_fifo #(.DATA_WIDTH(8), .DEPTH(FIFO_DEPTH)) u_rx_fifo (
        .clk(PCLK),
        .rst_n(PRESETn),
        .push(rx_fifo_push),
        .push_data(rx_data),
        .pop(rx_fifo_pop),
        .front_data(rx_front_data),
        .full(rx_full),
        .empty(rx_empty)
    );
endmodule
