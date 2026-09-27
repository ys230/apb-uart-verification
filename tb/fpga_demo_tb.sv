module fpga_demo_tb #(
    parameter int WAIT_CYCLES = 0
);
    timeunit 1ns;
    timeprecision 1ps;

    // Simulation clock and baud are chosen for speed, not as board settings.
    localparam int DIVISOR = 32;
    localparam time BIT_TIME = 320ns;
    logic clk = 1'b0;
    logic reset_n = 1'b0;
    logic uart_rx = 1'b1;
    logic uart_tx;
    logic ready;
    logic error;
    byte unsigned expected[$];
    int checked_frames = 0;
    int wait_edges = 0;
    int reset_epoch = 0;
    logic checks_active;

    initial forever #5ns clk = !clk;
    always @(negedge reset_n) reset_epoch <= reset_epoch + 1;

    fpga_uart_demo #(
        .CLK_HZ(100_000_000), .BAUD_RATE(3_125_000),
        .WAIT_CYCLES(WAIT_CYCLES)
    ) dut (.*);

    always_ff @(posedge clk or negedge dut.core_reset_n) begin
        if (!dut.core_reset_n) checks_active <= 1'b0;
        else checks_active <= 1'b1;
    end

    ap_master_holds_wait: assert property (
        @(posedge clk)
        (checks_active && dut.psel && dut.penable && !dut.pready) |=>
        (!checks_active || (dut.psel && dut.penable &&
         $stable({dut.pwrite, dut.paddr, dut.pwdata})))
    ) else $fatal(1, "APB request changed before PREADY");

    ap_master_setup: assert property (
        @(posedge clk)
        (checks_active && dut.psel && !dut.penable) |=>
        (!checks_active || (dut.psel && dut.penable))
    ) else $fatal(1, "APB SETUP was not followed by ACCESS");

    always @(posedge clk) begin
        if (checks_active && dut.psel && dut.penable && !dut.pready)
            wait_edges <= wait_edges + 1;
    end

    // Independent serial-pin monitor; it never reads the DUT's TX data/FIFO.
    initial forever begin : monitor
        byte unsigned received;
        byte unsigned wanted;
        int frame_epoch;
        @(negedge uart_tx);
        frame_epoch = reset_epoch;
        #(BIT_TIME / 2);
        if (!reset_n || frame_epoch != reset_epoch) disable monitor;
        if (uart_tx !== 1'b0) $fatal(1, "Invalid UART TX start bit");
        for (int bit_index = 0; bit_index < 8; bit_index++) begin
            #(BIT_TIME);
            if (!reset_n || frame_epoch != reset_epoch) disable monitor;
            received[bit_index] = uart_tx;
        end
        #(BIT_TIME);
        if (!reset_n || frame_epoch != reset_epoch) disable monitor;
        if (uart_tx !== 1'b1) $fatal(1, "Invalid UART TX stop bit");
        if (expected.size() == 0) $fatal(1, "Unexpected TX frame %02x", received);
        wanted = expected.pop_front();
        if (received != wanted)
            $fatal(1, "Echo mismatch: wanted=%02x received=%02x", wanted, received);
        checked_frames++;
    end

    task automatic wait_ready;
        repeat (64 + 8 * WAIT_CYCLES) begin
            @(negedge clk);
            if (ready) begin
                if (error) $fatal(1, "ready and error both high");
                return;
            end
        end
        $fatal(1, "UART initialization timed out");
    endtask

    task automatic reset_demo;
        @(negedge clk);
        reset_n = 1'b0;
        uart_rx = 1'b1;
        expected.delete();
        repeat (4) @(negedge clk);
        if (uart_tx !== 1'b1 || ready || error)
            $fatal(1, "Reset did not clear outputs");
        // Deliberately release between clock edges.
        #2ns reset_n = 1'b1;
        #1ns;
        if (dut.core_reset_n) $fatal(1, "Reset released asynchronously");
        @(negedge clk);
        if (dut.core_reset_n) $fatal(1, "Reset release used fewer than two clocks");
        wait_ready();
        if (dut.u_uart.baud_div != 16'(DIVISOR))
            $fatal(1, "Master did not program baud divider");
    endtask

    task automatic drive_frame(input byte unsigned data,
                               input int bit_cycles = DIVISOR,
                               input bit good_stop = 1'b1);
        @(negedge clk);
        uart_rx = 1'b0;
        repeat (bit_cycles) @(negedge clk);
        for (int bit_index = 0; bit_index < 8; bit_index++) begin
            uart_rx = data[bit_index];
            repeat (bit_cycles) @(negedge clk);
        end
        uart_rx = good_stop;
        repeat (bit_cycles) @(negedge clk);
        uart_rx = 1'b1;
    endtask

    task automatic send_byte(input byte unsigned data,
                             input int bit_cycles = DIVISOR);
        expected.push_back(data);
        drive_frame(data, bit_cycles);
    endtask

    task automatic drain_echo;
        repeat (16 * DIVISOR * 20) begin
            @(negedge clk);
            if (error) $fatal(1, "Demo fault during normal echo");
            if (expected.size() == 0) begin
                repeat (2 * DIVISOR) @(negedge clk);
                return;
            end
        end
        $fatal(1, "Echo timeout: pending=%0d", expected.size());
    endtask

    task automatic check_fault;
        repeat (64 + 8 * WAIT_CYCLES) begin
            @(negedge clk);
            if (error) begin
                if (ready || dut.psel) $fatal(1, "Fault did not halt APB master");
                repeat (8) @(negedge clk);
                if (!error || ready || dut.psel) $fatal(1, "Fault was not sticky");
                return;
            end
        end
        $fatal(1, "Expected demo fault was not reported");
    endtask

    initial begin : test
        reset_demo();
        // All byte values, in chunks matching the host's stop-and-wait mode.
        for (int chunk = 0; chunk < 16; chunk++) begin
            for (int index = 0; index < 16; index++)
                send_byte(8'(16 * chunk + index));
            drain_echo();
        end
        // Two bounded baud-mismatch cases, not a blanket tolerance guarantee.
        send_byte(8'h55, DIVISOR - 1);
        drain_echo();
        send_byte(8'haa, DIVISOR + 1);
        drain_echo();

        // Abort an incoming frame; it must not be echoed after reinitialization.
        @(negedge clk);
        uart_rx = 1'b0;
        repeat (3 * DIVISOR) @(negedge clk);
        reset_demo();
        repeat (12 * DIVISOR) @(negedge clk);
        send_byte(8'ha5);
        drain_echo();

        // Framing failure is read through STATUS and shown on the error output.
        drive_frame(8'h00, DIVISOR, 1'b0);
        check_fault();
        reset_demo();
        send_byte(8'h3c);
        drain_echo();

        // Inject one error response on a STATUS read. The master must halt,
        // rather than interpret PRDATA or continue issuing transfers.
        while (!(dut.psel && dut.penable && dut.pready &&
                 !dut.pwrite && dut.paddr == 32'h0000_0004)) @(negedge clk);
        force dut.pslverr = 1'b1;
        @(posedge clk);
        @(negedge clk);
        release dut.pslverr;
        check_fault();
        reset_demo();
        send_byte(8'hc3);
        drain_echo();

        if (checked_frames != 261) $fatal(1, "Wrong checked frame count");
        if ((WAIT_CYCLES > 0) && (wait_edges == 0))
            $fatal(1, "Wait-state test did not exercise a wait");
        $display("FPGA_DEMO_PASS wait=%0d echoed=%0d wait_edges=%0d reset_abort=1 framing_fault=1 apb_fault=1",
                 WAIT_CYCLES, checked_frames, wait_edges);
        $finish;
    end

    initial begin
        #5ms;
        $fatal(1, "Global FPGA demo test timeout");
    end
endmodule
