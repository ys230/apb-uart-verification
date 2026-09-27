`timescale 1ns/1ps

// Pin-level, self-checking testbench for the APB3 UART.
// All checks use the public APB and UART interfaces; no DUT internals are read.
module tb_top #(
    parameter int WAIT_CYCLES = 0,
    parameter int FIFO_DEPTH = 16
) ();
    localparam logic [31:0] CTRL     = 32'h00;
    localparam logic [31:0] STATUS   = 32'h04;
    localparam logic [31:0] SCRATCH  = 32'h08;
    localparam logic [31:0] BAUD_DIV = 32'h0c;
    localparam logic [31:0] TXDATA   = 32'h10;
    localparam logic [31:0] RXDATA   = 32'h14;

    logic        PCLK = 1'b0;
    logic        PRESETn = 1'b0;
    logic        PSEL = 1'b0;
    logic        PENABLE = 1'b0;
    logic        PWRITE = 1'b0;
    logic [31:0] PADDR = 32'b0;
    logic [31:0] PWDATA = 32'b0;
    logic [31:0] PRDATA;
    logic        PREADY;
    logic        PSLVERR;
    logic        uart_rx = 1'b1;
    logic        uart_tx;

    apb_uart #(
        .WAIT_CYCLES(WAIT_CYCLES),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .PCLK(PCLK), .PRESETn(PRESETn),
        .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
        .PADDR(PADDR), .PWDATA(PWDATA),
        .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERR(PSLVERR),
        .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    always #5 PCLK <= ~PCLK;

    byte unsigned tx_expected[$];
    byte unsigned rx_expected[$];
    bit tx_monitor_active = 1'b0;
    int unsigned baud_model = 16;
    int unsigned prng_state;
    int unsigned seed_value;
    int unsigned random_target = 1000;
    string test_name;

    int unsigned apb_transactions;
    int unsigned random_apb_transactions;
    int unsigned apb_errors;
    int unsigned apb_reads;
    int unsigned apb_writes;
    int unsigned tx_frames;
    int unsigned rx_frames;
    int unsigned rx_bad_stops;
    int unsigned rx_false_starts;
    int unsigned rx_overflow_frames;
    int unsigned rx_period_31_frames;
    int unsigned rx_period_33_frames;
    int unsigned tx_full_rejects;
    int unsigned rx_empty_rejects;
    int unsigned reset_aborts;
    int unsigned apb_coverage [0:1][0:1][0:2];
    int unsigned baud_min_seen = 32'hffff_ffff;
    int unsigned baud_max_seen;

    // The monitor samples every bit at its center. It compares decoded bytes
    // against the APB write order, so a DUT TX loopback cannot mask an error.
    initial begin : tx_pin_monitor
        byte unsigned expected_byte;
        int unsigned div_at_start;
        wait (PRESETn === 1'b1);
        forever begin
            @(negedge uart_tx);
            if (PRESETn === 1'b1) begin
                if (tx_expected.size() == 0)
                    $fatal(1, "Unexpected UART TX start at %0t", $time);
                expected_byte = tx_expected.pop_front();
                div_at_start = baud_model;
                tx_monitor_active = 1'b1;
                if (div_at_start < baud_min_seen) baud_min_seen = div_at_start;
                if (div_at_start > baud_max_seen) baud_max_seen = div_at_start;
                // A reset aborts an active frame. The other branch interrupts
                // sampling immediately, then the reset task clears the queue.
                fork
                    begin : decode_frame
                        int unsigned bit_index;
                        bit expected_level;
                        // Check each PCLK cycle, including all cycles of the
                        // stop bit. This catches wrong bit width as well as
                        // wrong data or bit order.
                        for (int sample = 0; sample < 10 * div_at_start; sample++) begin
                            @(negedge PCLK);
                            bit_index = sample / div_at_start;
                            if (bit_index == 0) expected_level = 1'b0;
                            else if (bit_index == 9) expected_level = 1'b1;
                            else expected_level = expected_byte[bit_index - 1];
                            if (uart_tx !== expected_level)
                                $fatal(1, "TX pin mismatch frame=%0d bit=%0d cycle=%0d expected=%0b got=%0b byte=%02x at %0t",
                                       tx_frames, bit_index, sample % div_at_start,
                                       expected_level, uart_tx, expected_byte, $time);
                        end
                        tx_frames++;
                    end
                    begin : reset_interrupt
                        @(negedge PRESETn);
                    end
                join_any
                disable fork;
                tx_monitor_active = 1'b0;
            end
        end
    end

    initial begin : global_watchdog
        #20_000_000;
        $fatal(1, "Global simulation timeout test=%s seed=%0d", test_name, seed_value);
    end

    task automatic reset_dut;
        @(negedge PCLK);
        PRESETn = 1'b0;
        PSEL = 1'b0;
        PENABLE = 1'b0;
        PWRITE = 1'b0;
        PADDR = '0;
        PWDATA = '0;
        uart_rx = 1'b1;
        tx_expected.delete();
        rx_expected.delete();
        baud_model = 16;
        repeat (4) @(negedge PCLK);
        PRESETn = 1'b1;
        repeat (2) @(negedge PCLK);
        if (uart_tx !== 1'b1)
            $fatal(1, "TX pin is not idle-high after reset");
    endtask

    // The optional keep_selected argument permits a true APB back-to-back pair:
    // the next call drives SETUP with PSEL still asserted after this ACCESS.
    task automatic apb_access(
        input logic [31:0] address,
        input bit write_enable,
        input logic [31:0] write_data,
        input bit keep_selected,
        output logic [31:0] read_data,
        output bit response_error
    );
        int unsigned wait_observed;
        logic [1:0] wait_bucket;
        @(negedge PCLK);
        PSEL = 1'b1;
        PENABLE = 1'b0;
        PWRITE = write_enable;
        PADDR = address;
        PWDATA = write_data;
        @(negedge PCLK);
        PENABLE = 1'b1;
        wait_observed = 0;
        forever begin
            @(posedge PCLK);
            if (PSEL !== 1'b1 || PENABLE !== 1'b1 ||
                PWRITE !== write_enable || PADDR !== address || PWDATA !== write_data)
                $fatal(1, "APB master signals changed during ACCESS addr=%08x", address);
            if (PREADY === 1'b1) begin
                read_data = PRDATA;
                response_error = PSLVERR;
                break;
            end
            if (PREADY !== 1'b0)
                $fatal(1, "PREADY unknown during ACCESS addr=%08x", address);
            wait_observed++;
            if (wait_observed > WAIT_CYCLES + 2)
                $fatal(1, "APB timeout addr=%08x wait=%0d", address, wait_observed);
        end
        if (wait_observed != WAIT_CYCLES)
            $fatal(1, "APB wait mismatch addr=%08x expected=%0d got=%0d",
                   address, WAIT_CYCLES, wait_observed);
        if (response_error !== 1'b0 && response_error !== 1'b1)
            $fatal(1, "PSLVERR unknown addr=%08x", address);
        apb_transactions++;
        if (write_enable) apb_writes++; else apb_reads++;
        if (response_error) apb_errors++;
        if (WAIT_CYCLES == 0) wait_bucket = 0;
        else if (WAIT_CYCLES == 1) wait_bucket = 1;
        else wait_bucket = 2;
        apb_coverage[int'(write_enable)][int'(response_error)][wait_bucket]++;
        if (!keep_selected) begin
            @(negedge PCLK);
            PSEL = 1'b0;
            PENABLE = 1'b0;
        end
    endtask

    task automatic apb_write_check(
        input logic [31:0] address,
        input logic [31:0] data,
        input bit expected_error,
        input bit keep_selected
    );
        logic [31:0] observed_data;
        bit observed_error;
        apb_access(address, 1'b1, data, keep_selected, observed_data, observed_error);
        if (observed_error !== expected_error)
            $fatal(1, "APB write response addr=%08x data=%08x expected_error=%0b got=%0b",
                   address, data, expected_error, observed_error);
        if (observed_data !== 32'b0)
            $fatal(1, "Write PRDATA must be zero addr=%08x got=%08x", address, observed_data);
    endtask

    task automatic apb_read_check(
        input logic [31:0] address,
        input bit expected_error,
        input logic [31:0] expected_data,
        input logic [31:0] mask,
        input bit keep_selected
    );
        logic [31:0] observed_data;
        bit observed_error;
        apb_access(address, 1'b0, 32'b0, keep_selected, observed_data, observed_error);
        if (observed_error !== expected_error)
            $fatal(1, "APB read response addr=%08x expected_error=%0b got=%0b",
                   address, expected_error, observed_error);
        if (expected_error && observed_data !== 32'b0)
            $fatal(1, "Error read data must be zero addr=%08x got=%08x", address, observed_data);
        if (!expected_error && ((observed_data & mask) !== (expected_data & mask)))
            $fatal(1, "APB read mismatch addr=%08x expected=%08x mask=%08x got=%08x",
                   address, expected_data, mask, observed_data);
    endtask

    task automatic tx_push(input byte unsigned value, input bit expected_error);
        // Queue before the APB handshake: TX may launch in the same clock edge.
        if (!expected_error) tx_expected.push_back(value);
        apb_write_check(TXDATA, {24'b0, value}, expected_error, 1'b0);
        if (expected_error) tx_full_rejects++;
    endtask

    task automatic rx_read_expected;
        byte unsigned expected_byte;
        if (rx_expected.size() == 0)
            $fatal(1, "TB RX expectation queue is empty");
        expected_byte = rx_expected.pop_front();
        apb_read_check(RXDATA, 1'b0, {24'b0, expected_byte}, 32'hffff_ffff, 1'b0);
    endtask

    task automatic rx_send_frame_period(input byte unsigned value, input bit bad_stop,
                                        input int unsigned bit_cycles);
        @(negedge PCLK);
        uart_rx = 1'b0;
        repeat (bit_cycles) @(negedge PCLK);
        for (int bit_index = 0; bit_index < 8; bit_index++) begin
            uart_rx = value[bit_index];
            repeat (bit_cycles) @(negedge PCLK);
        end
        uart_rx = bad_stop ? 1'b0 : 1'b1;
        repeat (bit_cycles) @(negedge PCLK);
        uart_rx = 1'b1;
        repeat (5) @(negedge PCLK);
        if (bad_stop) rx_bad_stops++;
        else begin
            rx_expected.push_back(value);
            rx_frames++;
            if (baud_model == 32 && bit_cycles == 31) rx_period_31_frames++;
            if (baud_model == 32 && bit_cycles == 33) rx_period_33_frames++;
            if (baud_model < baud_min_seen) baud_min_seen = baud_model;
            if (baud_model > baud_max_seen) baud_max_seen = baud_model;
        end
    endtask

    task automatic rx_send_frame(input byte unsigned value, input bit bad_stop);
        rx_send_frame_period(value, bad_stop, baud_model);
    endtask

    task automatic rx_false_start;
        @(negedge PCLK);
        uart_rx = 1'b0;
        repeat (2) @(negedge PCLK);
        uart_rx = 1'b1;
        repeat (baud_model + 8) @(negedge PCLK);
        rx_false_starts++;
    endtask

    task automatic wait_tx_drain;
        int unsigned limit;
        int unsigned n;
        limit = (tx_expected.size() + 3) * (baud_model * 11 + 20);
        for (n = 0; n < limit; n++) begin
            @(negedge PCLK);
            if (tx_expected.size() == 0 && !tx_monitor_active) break;
        end
        if (n == limit)
            $fatal(1, "TX drain timeout remaining=%0d active=%0b", tx_expected.size(), tx_monitor_active);
        // A second transfer from one APB handshake becomes visible here.
        repeat (2 * baud_model + 8) @(negedge PCLK);
    endtask

    function automatic int unsigned next_random();
        prng_state = prng_state ^ (prng_state << 13);
        prng_state = prng_state ^ (prng_state >> 17);
        prng_state = prng_state ^ (prng_state << 5);
        return prng_state;
    endfunction

    task automatic test_apb;
        logic [31:0] scratch_model;
        reset_dut();
        apb_read_check(CTRL,     1'b0, 32'h0, 32'hffff_ffff, 1'b0);
        apb_read_check(SCRATCH,  1'b0, 32'h0, 32'hffff_ffff, 1'b0);
        apb_read_check(BAUD_DIV, 1'b0, 32'd16, 32'hffff_ffff, 1'b0);
        apb_read_check(STATUS,   1'b0, 32'h4, 32'hffff_ffff, 1'b0);

        apb_write_check(SCRATCH, 32'hdeaf_beef, 1'b0, 1'b0);
        apb_read_check(SCRATCH, 1'b0, 32'hdeaf_beef, 32'hffff_ffff, 1'b0);
        apb_write_check(CTRL, 32'hffff_ffff, 1'b0, 1'b0);
        apb_read_check(CTRL, 1'b0, 32'h3, 32'hffff_ffff, 1'b0);
        apb_write_check(CTRL, 32'h0, 1'b0, 1'b0);

        apb_write_check(BAUD_DIV, 32'd4, 1'b0, 1'b0);
        baud_model = 4;
        apb_read_check(BAUD_DIV, 1'b0, 32'd4, 32'hffff_ffff, 1'b0);
        apb_write_check(BAUD_DIV, 32'd65535, 1'b0, 1'b0);
        baud_model = 65535;
        apb_read_check(BAUD_DIV, 1'b0, 32'd65535, 32'hffff_ffff, 1'b0);
        apb_write_check(BAUD_DIV, 32'd3, 1'b1, 1'b0);
        apb_write_check(BAUD_DIV, 32'd65536, 1'b1, 1'b0);
        apb_read_check(BAUD_DIV, 1'b0, 32'd65535, 32'hffff_ffff, 1'b0);
        apb_write_check(BAUD_DIV, 32'd16, 1'b0, 1'b0);
        baud_model = 16;

        apb_write_check(STATUS, 32'hffff_ffff, 1'b1, 1'b0);
        apb_read_check(TXDATA, 1'b1, 32'b0, 32'hffff_ffff, 1'b0);
        apb_read_check(RXDATA, 1'b1, 32'b0, 32'hffff_ffff, 1'b0);
        rx_empty_rejects++;
        apb_write_check(RXDATA, 32'h12, 1'b1, 1'b0);
        apb_write_check(32'h18, 32'h55, 1'b1, 1'b0);
        apb_read_check(32'h18, 1'b1, 32'b0, 32'hffff_ffff, 1'b0);
        apb_write_check(SCRATCH + 1, 32'hbad, 1'b1, 1'b0);
        apb_read_check(BAUD_DIV + 2, 1'b1, 32'b0, 32'hffff_ffff, 1'b0);
        apb_read_check(SCRATCH, 1'b0, 32'hdeaf_beef, 32'hffff_ffff, 1'b0);

        // Keep PSEL high across ACCESS -> SETUP -> ACCESS.
        apb_write_check(SCRATCH, 32'h1234_5678, 1'b0, 1'b1);
        apb_read_check(SCRATCH, 1'b0, 32'h1234_5678, 32'hffff_ffff, 1'b0);

        // Assert reset before the completion edge of a pending access.
        @(negedge PCLK);
        PSEL = 1'b1;
        PENABLE = 1'b0;
        PWRITE = 1'b1;
        PADDR = SCRATCH;
        PWDATA = 32'hfeed_face;
        @(negedge PCLK);
        PENABLE = 1'b1;
        #1 PRESETn = 1'b0;
        reset_aborts++;
        @(negedge PCLK);
        PSEL = 1'b0;
        PENABLE = 1'b0;
        repeat (3) @(negedge PCLK);
        PRESETn = 1'b1;
        baud_model = 16;
        scratch_model = 0;
        apb_read_check(SCRATCH, 1'b0, scratch_model, 32'hffff_ffff, 1'b0);
        apb_read_check(CTRL, 1'b0, 32'b0, 32'hffff_ffff, 1'b0);
        apb_read_check(BAUD_DIV, 1'b0, 32'd16, 32'hffff_ffff, 1'b0);
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);
    endtask

    task automatic test_tx;
        int unsigned before_frames;
        reset_dut();
        before_frames = tx_frames;
        apb_write_check(CTRL, 32'h1, 1'b0, 1'b0);
        tx_push(8'h00, 1'b0);
        // The active transmitter must reject a baud change.
        wait (uart_tx === 1'b0);
        apb_write_check(BAUD_DIV, 32'd20, 1'b1, 1'b0);
        apb_read_check(BAUD_DIV, 1'b0, 32'd16, 32'hffff_ffff, 1'b0);
        tx_push(8'hff, 1'b0);
        tx_push(8'h55, 1'b0);
        tx_push(8'haa, 1'b0);
        tx_push(8'h81, 1'b0);
        tx_push(8'h7e, 1'b0);
        wait_tx_drain();
        if (tx_frames != before_frames + 6)
            $fatal(1, "TX frame count expected=%0d got=%0d", before_frames + 6, tx_frames);
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);

        // FIFO full and wraparound, with TX disabled while filling.
        reset_dut();
        before_frames = tx_frames;
        for (int i = 0; i < FIFO_DEPTH; i++) tx_push(byte'(i ^ 32'ha5), 1'b0);
        apb_read_check(STATUS, 1'b0, 32'h5, 32'hffff_ffff, 1'b0);
        tx_push(8'hee, 1'b1);
        apb_write_check(CTRL, 32'h1, 1'b0, 1'b0);
        wait_tx_drain();
        if (tx_frames != before_frames + FIFO_DEPTH)
            $fatal(1, "TX full-boundary frame count expected=%0d got=%0d",
                   before_frames + FIFO_DEPTH, tx_frames);
        tx_push(8'h96, 1'b0);
        wait_tx_drain();
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);

        apb_write_check(BAUD_DIV, 32'd4, 1'b0, 1'b0);
        baud_model = 4;
        tx_push(8'h3c, 1'b0);
        wait_tx_drain();
        apb_write_check(BAUD_DIV, 32'd17, 1'b0, 1'b0);
        baud_model = 17;
        tx_push(8'hc3, 1'b0);
        wait_tx_drain();

        apb_write_check(BAUD_DIV, 32'd5, 1'b0, 1'b0);
        baud_model = 5;
        tx_push(8'h5a, 1'b0);
        wait_tx_drain();

        // A completed ACCESS held for extra clocks must push exactly once.
        reset_dut();
        before_frames = tx_frames;
        tx_expected.push_back(8'h5b);
        @(negedge PCLK);
        PSEL = 1'b1;
        PENABLE = 1'b0;
        PWRITE = 1'b1;
        PADDR = TXDATA;
        PWDATA = 32'h5b;
        @(negedge PCLK);
        PENABLE = 1'b1;
        for (int i = 0; i < WAIT_CYCLES; i++) begin
            @(posedge PCLK);
            if (PREADY !== 1'b0)
                $fatal(1, "Held TXDATA ACCESS completed before expected wait count");
        end
        @(posedge PCLK);
        if (PREADY !== 1'b1 || PSLVERR !== 1'b0)
            $fatal(1, "Held TXDATA ACCESS did not complete successfully");
        apb_transactions++;
        apb_writes++;
        for (int i = 0; i < 4; i++) begin
            @(posedge PCLK);
            if (PREADY !== 1'b0)
                $fatal(1, "Held TXDATA ACCESS completed a second time");
        end
        @(negedge PCLK);
        PSEL = 1'b0;
        PENABLE = 1'b0;
        apb_write_check(CTRL, 32'h1, 1'b0, 1'b0);
        wait_tx_drain();
        if (tx_frames != before_frames + 1)
            $fatal(1, "Held TXDATA ACCESS caused duplicate/lost frame count=%0d expected=%0d",
                   tx_frames, before_frames + 1);

        // Reset while the start/data bits are being transmitted.
        reset_dut();
        before_frames = tx_frames;
        apb_write_check(CTRL, 32'h1, 1'b0, 1'b0);
        tx_push(8'h55, 1'b0);
        wait (uart_tx === 1'b0);
        repeat (3 * baud_model) @(negedge PCLK);
        reset_dut();
        reset_aborts++;
        repeat (12 * baud_model) @(negedge PCLK);
        if (uart_tx !== 1'b1 || tx_frames != before_frames)
            $fatal(1, "TX reset did not abort active frame");
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);
    endtask

    task automatic test_rx;
        reset_dut();
        apb_write_check(CTRL, 32'h2, 1'b0, 1'b0);
        rx_send_frame(8'h00, 1'b0);
        rx_send_frame(8'hff, 1'b0);
        rx_send_frame(8'h55, 1'b0);
        rx_send_frame(8'haa, 1'b0);
        rx_send_frame(8'h81, 1'b0);
        apb_read_check(STATUS, 1'b0, 32'h0, 32'hffff_ffff, 1'b0);
        for (int i = 0; i < 5; i++) rx_read_expected();
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);
        apb_read_check(RXDATA, 1'b1, 32'b0, 32'hffff_ffff, 1'b0);
        rx_empty_rejects++;

        rx_false_start();
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);
        rx_send_frame(8'h37, 1'b1);
        apb_read_check(STATUS, 1'b0, 32'h24, 32'hffff_ffff, 1'b0);
        rx_send_frame(8'h5a, 1'b0);
        rx_read_expected();
        apb_read_check(STATUS, 1'b0, 32'h24, 32'hffff_ffff, 1'b0);

        // Disable during a partial frame. Re-enable and prove no stale byte.
        reset_dut();
        apb_write_check(CTRL, 32'h2, 1'b0, 1'b0);
        fork
            begin
                @(negedge PCLK);
                uart_rx = 1'b0;
                repeat (3 * baud_model) @(negedge PCLK);
                uart_rx = 1'b1;
            end
            begin
                repeat (baud_model) @(negedge PCLK);
                apb_write_check(CTRL, 32'h0, 1'b0, 1'b0);
            end
        join
        repeat (baud_model + 6) @(negedge PCLK);
        apb_write_check(CTRL, 32'h2, 1'b0, 1'b0);
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);
        rx_send_frame(8'h69, 1'b0);
        rx_read_expected();

        // BAUD_DIV cannot change while the receiver is sampling a frame.
        fork
            begin
                rx_send_frame(8'ha6, 1'b0);
            end
            begin
                wait (uart_rx === 1'b0);
                repeat (2 * baud_model) @(negedge PCLK);
                apb_write_check(BAUD_DIV, 32'd20, 1'b1, 1'b0);
            end
        join
        apb_read_check(BAUD_DIV, 1'b0, 32'd16, 32'hffff_ffff, 1'b0);
        rx_read_expected();

        // Reset during a partial frame clears RX state and FIFO.
        @(negedge PCLK);
        uart_rx = 1'b0;
        repeat (3 * baud_model) @(negedge PCLK);
        reset_dut();
        reset_aborts++;
        repeat (12 * baud_model) @(negedge PCLK);
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);
        apb_write_check(BAUD_DIV, 32'd5, 1'b0, 1'b0);
        baud_model = 5;
        apb_write_check(CTRL, 32'h2, 1'b0, 1'b0);
        rx_send_frame(8'h96, 1'b0);
        rx_read_expected();
        apb_write_check(BAUD_DIV, 32'd4, 1'b0, 1'b0);
        baud_model = 4;
        rx_send_frame(8'h3c, 1'b0);
        rx_read_expected();
        // At DUT divider 32, independently drive frames at 31 and 33 clocks
        // per bit. These are the measured +/-1/32 rate-offset cases.
        apb_write_check(BAUD_DIV, 32'd32, 1'b0, 1'b0);
        baud_model = 32;
        rx_send_frame_period(8'hc5, 1'b0, 31);
        rx_read_expected();
        rx_send_frame_period(8'h3a, 1'b0, 33);
        rx_read_expected();
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);

        // Preserve the oldest FIFO_DEPTH bytes and drop new bytes on overflow.
        reset_dut();
        apb_write_check(CTRL, 32'h2, 1'b0, 1'b0);
        for (int i = 0; i < FIFO_DEPTH; i++) rx_send_frame(byte'(i ^ 32'h5a), 1'b0);
        apb_read_check(STATUS, 1'b0, 32'h8, 32'hffff_ffff, 1'b0);
        rx_send_frame(8'he7, 1'b0);
        // The extra byte was sent on the pin, but must not enter the RX queue.
        if (rx_expected.size() == 0)
            $fatal(1, "RX expectation queue unexpectedly empty");
        void'(rx_expected.pop_back());
        rx_overflow_frames++;
        apb_read_check(STATUS, 1'b0, 32'h18, 32'hffff_ffff, 1'b0);
        for (int i = 0; i < FIFO_DEPTH; i++) rx_read_expected();
        apb_read_check(STATUS, 1'b0, 32'h14, 32'hffff_ffff, 1'b0);
        reset_dut();
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);
    endtask

    task automatic test_random;
        int unsigned before_apb;
        int unsigned queued_tx;
        int unsigned op;
        int unsigned r;
        logic [31:0] scratch_model;
        logic [31:0] ctrl_model;
        logic [31:0] baud_write;
        byte unsigned value;
        reset_dut();
        before_apb = apb_transactions;
        queued_tx = 0;
        scratch_model = 0;
        ctrl_model = 0;
        for (int unsigned i = 0; i < random_target; i++) begin
            r = next_random();
            op = r % 12;
            case (op)
                0: begin
                    scratch_model = next_random();
                    apb_write_check(SCRATCH, scratch_model, 1'b0, 1'b0);
                end
                1: apb_read_check(SCRATCH, 1'b0, scratch_model, 32'hffff_ffff, 1'b0);
                2: begin
                    ctrl_model = (r >> 8) & 32'h2; // TX remains disabled until drain.
                    apb_write_check(CTRL, ctrl_model | 32'hffff_fffc, 1'b0, 1'b0);
                end
                3: apb_read_check(CTRL, 1'b0, ctrl_model, 32'hffff_ffff, 1'b0);
                4: begin
                    case ((r >> 8) % 5)
                        0: baud_write = 4;
                        1: baud_write = 8;
                        2: baud_write = 16;
                        3: baud_write = 17;
                        default: baud_write = 32;
                    endcase
                    apb_write_check(BAUD_DIV, baud_write, 1'b0, 1'b0);
                    baud_model = baud_write;
                end
                5: begin
                    case ((r >> 8) % 4)
                        0: baud_write = 0;
                        1: baud_write = 3;
                        2: baud_write = 65536;
                        default: baud_write = 32'hffff_ffff;
                    endcase
                    apb_write_check(BAUD_DIV, baud_write, 1'b1, 1'b0);
                end
                6: apb_read_check(BAUD_DIV, 1'b0, baud_model, 32'hffff_ffff, 1'b0);
                7: begin
                    value = byte'(next_random());
                    if (queued_tx < FIFO_DEPTH) begin
                        tx_push(value, 1'b0);
                        queued_tx++;
                    end else tx_push(value, 1'b1);
                end
                8: apb_read_check(STATUS, 1'b0,
                                  (queued_tx == FIFO_DEPTH ? 32'h5 : 32'h4),
                                  32'hffff_ffff, 1'b0);
                9: begin
                    apb_read_check(RXDATA, 1'b1, 32'b0, 32'hffff_ffff, 1'b0);
                    rx_empty_rejects++;
                end
                10: begin
                    if (r[8]) apb_write_check(32'h18, r, 1'b1, 1'b0);
                    else apb_read_check(32'h1c, 1'b1, 32'b0, 32'hffff_ffff, 1'b0);
                end
                default: begin
                    if (r[8]) apb_write_check(STATUS, r, 1'b1, 1'b0);
                    else apb_read_check(TXDATA, 1'b1, 32'b0, 32'hffff_ffff, 1'b0);
                end
            endcase
            random_apb_transactions++;
        end
        if (apb_transactions - before_apb != random_target ||
            random_apb_transactions != random_target)
            $fatal(1, "Random APB count mismatch requested=%0d observed=%0d",
                   random_target, apb_transactions - before_apb);

        // Seeded UART RX bytes and APB FIFO reads accompany the random APB run.
        apb_write_check(BAUD_DIV, 32'd16, 1'b0, 1'b0);
        baud_model = 16;
        apb_write_check(CTRL, 32'h2, 1'b0, 1'b0);
        for (int i = 0; i < 8; i++) begin
            value = byte'(next_random());
            rx_send_frame(value, 1'b0);
        end
        for (int i = 0; i < 8; i++) rx_read_expected();
        apb_read_check(STATUS, 1'b0,
                       (queued_tx == FIFO_DEPTH ? 32'h5 : 32'h4),
                       32'hffff_ffff, 1'b0);
        apb_write_check(CTRL, 32'h1, 1'b0, 1'b0);
        wait_tx_drain();
        apb_read_check(STATUS, 1'b0, 32'h4, 32'hffff_ffff, 1'b0);
    endtask

    initial begin : run_tests
        int parsed_seed;
        int parsed_target;
        if (!$value$plusargs("TEST=%s", test_name)) test_name = "all";
        if (!$value$plusargs("SEED=%d", parsed_seed)) parsed_seed = 1;
        if (!$value$plusargs("N_TRANSACTIONS=%d", parsed_target)) parsed_target = 1000;
        if (parsed_target < 1) $fatal(1, "N_TRANSACTIONS must be positive");
        random_target = parsed_target;
        seed_value = parsed_seed;
        prng_state = seed_value == 0 ? 32'h6d2b_79f5 : seed_value;
        if ($test$plusargs("WAVES")) begin
            $dumpfile("build/tb_top.vcd");
            $dumpvars(0, tb_top);
        end
        case (test_name)
            "apb": test_apb();
            "tx": test_tx();
            "rx": test_rx();
            "random": test_random();
            "all": begin
                test_apb();
                test_tx();
                test_rx();
                test_random();
            end
            default: $fatal(1, "Unknown TEST=%s", test_name);
        endcase
        if (tx_expected.size() != 0 || tx_monitor_active || rx_expected.size() != 0)
            $fatal(1, "Final scoreboard queues TX=%0d RX=%0d active=%0b",
                   tx_expected.size(), rx_expected.size(), tx_monitor_active);
        if (test_name == "random" || test_name == "all") begin
            if (random_apb_transactions != random_target)
                $fatal(1, "Random APB target missed: %0d/%0d",
                       random_apb_transactions, random_target);
        end
        $display("COVERAGE apb_reads=%0d apb_writes=%0d apb_errors=%0d wait_cycles=%0d random_apb=%0d",
                 apb_reads, apb_writes, apb_errors, WAIT_CYCLES, random_apb_transactions);
        for (int w = 0; w < 2; w++)
            for (int e = 0; e < 2; e++)
                for (int b = 0; b < 3; b++)
                    if (apb_coverage[w][e][b] != 0)
                        $display("COVERAGE apb write=%0d error=%0d wait_bucket=%0d count=%0d",
                                 w, e, b, apb_coverage[w][e][b]);
        $display("COVERAGE uart tx_frames=%0d rx_frames=%0d bad_stop=%0d false_start=%0d overflow=%0d rx_period_31=%0d rx_period_33=%0d tx_full_reject=%0d rx_empty_reject=%0d reset_abort=%0d baud_min=%0d baud_max=%0d",
                 tx_frames, rx_frames, rx_bad_stops, rx_false_starts, rx_overflow_frames,
                 rx_period_31_frames, rx_period_33_frames,
                 tx_full_rejects, rx_empty_rejects, reset_aborts,
                 baud_min_seen == 32'hffff_ffff ? 0 : baud_min_seen, baud_max_seen);
        $display("TEST_PASS test=%s seed=%0d apb_transactions=%0d tx_frames=%0d rx_frames=%0d",
                 test_name, seed_value, apb_transactions, tx_frames, rx_frames);
        $finish;
    end
endmodule
