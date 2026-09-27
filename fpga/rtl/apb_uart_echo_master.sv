// A small APB master for exercising the UART without an embedded CPU.
module apb_uart_echo_master #(
    parameter int BAUD_DIV = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        psel,
    output logic        penable,
    output logic        pwrite,
    output logic [31:0] paddr,
    output logic [31:0] pwdata,
    input  logic [31:0] prdata,
    input  logic        pready,
    input  logic        pslverr,
    output logic        ready,
    output logic        error
);
    timeunit 1ns;
    timeprecision 1ps;

    typedef enum logic [2:0] {
        SET_BAUD, ENABLE_UART, POLL_STATUS, READ_RX, WRITE_TX
    } operation_t;
    operation_t operation;
    logic access_phase;
    logic [7:0] echo_byte;
    // All registers read here use only the low byte; the bus stays 32 bits.
    logic unused_prdata;
    assign unused_prdata = ^prdata[31:8];

    // Every transfer has a SETUP cycle followed by ACCESS. Address, data and
    // direction remain unchanged until PREADY completes ACCESS, even with waits.
    always_comb begin
        psel = rst_n && !error;
        penable = psel && access_phase;
        pwrite = 1'b0;
        paddr = 32'h0000_0004;
        pwdata = '0;
        case (operation)
            SET_BAUD: begin
                pwrite = 1'b1;
                paddr = 32'h0000_000c;
                pwdata = 32'(BAUD_DIV);
            end
            ENABLE_UART: begin
                pwrite = 1'b1;
                paddr = 32'h0000_0000;
                pwdata = 32'h0000_0003;
            end
            READ_RX: paddr = 32'h0000_0014;
            WRITE_TX: begin
                pwrite = 1'b1;
                paddr = 32'h0000_0010;
                pwdata = {24'd0, echo_byte};
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            operation <= SET_BAUD;
            access_phase <= 1'b0;
            echo_byte <= '0;
            ready <= 1'b0;
            error <= 1'b0;
        end else if (!error) begin
            if (!access_phase) begin
                access_phase <= 1'b1;
            end else if (pready) begin
                access_phase <= 1'b0;
                if (pslverr) begin
                    error <= 1'b1;
                    ready <= 1'b0;
                end else begin
                    case (operation)
                        SET_BAUD: operation <= ENABLE_UART;
                        ENABLE_UART: begin
                            ready <= 1'b1;
                            operation <= POLL_STATUS;
                        end
                        POLL_STATUS: begin
                            if (prdata[5] || prdata[4]) begin
                                // Framing/overflow are sticky in the UART. Stop
                                // and show an error until the board is reset.
                                error <= 1'b1;
                                ready <= 1'b0;
                            end else if (!prdata[2] && !prdata[0]) begin
                                operation <= READ_RX;
                            end
                        end
                        READ_RX: begin
                            echo_byte <= prdata[7:0];
                            operation <= WRITE_TX;
                        end
                        WRITE_TX: operation <= POLL_STATUS;
                        default: begin
                            error <= 1'b1;
                            ready <= 1'b0;
                        end
                    endcase
                end
            end
        end
    end

    // This is the only TX FIFO writer. Once POLL_STATUS observes room, the
    // FIFO cannot become full before WRITE_TX, so the popped RX byte is safe.
endmodule
