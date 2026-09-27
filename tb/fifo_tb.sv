`timescale 1ns/1ps

// Exercises the FIFO contract directly, including cases that APB and UART
// cannot force to occur on exactly the same clock edge.
module fifo_tb;
    localparam int DEPTH = 5; // Deliberately non-power-of-two for pointer wrap.

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic push = 1'b0;
    logic pop = 1'b0;
    logic [7:0] push_data = '0;
    logic [7:0] front_data;
    logic full;
    logic empty;
    byte unsigned model_q[$];
    int unsigned coverage [0:2][0:3];
    int unsigned accepted_pushes;
    int unsigned accepted_pops;
    int unsigned cycles;
    int unsigned random_state = 32'hcafe_4731;

    sync_fifo #(.DATA_WIDTH(8), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n), .push(push), .push_data(push_data),
        .pop(pop), .front_data(front_data), .full(full), .empty(empty)
    );

    always #5 clk <= ~clk;

    initial begin
        #100_000;
        $fatal(1, "FIFO test timeout");
    end

    function automatic int unsigned next_random();
        random_state = random_state ^ (random_state << 13);
        random_state = random_state ^ (random_state >> 17);
        random_state = random_state ^ (random_state << 5);
        return random_state;
    endfunction

    task automatic check_state;
        if (empty !== (model_q.size() == 0))
            $fatal(1, "FIFO empty mismatch cycle=%0d count=%0d empty=%0b",
                   cycles, model_q.size(), empty);
        if (full !== (model_q.size() == DEPTH))
            $fatal(1, "FIFO full mismatch cycle=%0d count=%0d full=%0b",
                   cycles, model_q.size(), full);
        if (model_q.size() == 0) begin
            if (front_data !== 8'h00)
                $fatal(1, "FIFO empty front data should be zero, got=%02x", front_data);
        end else if (front_data !== model_q[0]) begin
            $fatal(1, "FIFO front mismatch cycle=%0d count=%0d expected=%02x got=%02x",
                   cycles, model_q.size(), model_q[0], front_data);
        end
    endtask

    task automatic cycle(input bit request_push, input bit request_pop,
                         input byte unsigned value);
        bit accept_push;
        bit accept_pop;
        byte unsigned discarded;
        logic [1:0] state_bin;
        @(negedge clk);
        push = request_push;
        pop = request_pop;
        push_data = value;
        check_state();
        if (model_q.size() == 0) state_bin = 0;
        else if (model_q.size() == DEPTH) state_bin = 2;
        else state_bin = 1;
        coverage[state_bin][{request_push, request_pop}]++;
        accept_push = request_push && model_q.size() < DEPTH;
        accept_pop = request_pop && model_q.size() > 0;
        @(posedge clk);
        if (accept_pop) begin
            discarded = model_q.pop_front();
            if (discarded !== front_data)
                $fatal(1, "FIFO popped value mismatch expected=%02x got=%02x",
                       discarded, front_data);
            accepted_pops++;
        end
        if (accept_push) begin
            model_q.push_back(value);
            accepted_pushes++;
        end
        cycles++;
        #1;
        check_state();
    endtask

    task automatic reach_count(input int unsigned target);
        while (model_q.size() < target)
            cycle(1'b1, 1'b0, byte'(accepted_pushes ^ 32'hb7));
        while (model_q.size() > target)
            cycle(1'b0, 1'b1, 8'h00);
    endtask

    initial begin : run
        logic [1:0] r;
        byte unsigned value;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        #1;
        check_state();

        // Hit every push/pop combination in empty, middle and full states.
        for (int state_bin = 0; state_bin < 3; state_bin++) begin
            for (int op = 0; op < 4; op++) begin
                case (state_bin)
                    0: reach_count(0);
                    1: reach_count(2);
                    default: reach_count(DEPTH);
                endcase
                cycle(bit'(op >> 1), bit'(op), byte'(32'h40 + op + 4 * state_bin));
            end
        end

        // Repeated wraparound at a non-power-of-two depth.
        for (int i = 0; i < 4 * DEPTH; i++) begin
            reach_count(DEPTH);
            cycle(1'b1, 1'b1, byte'(i ^ 32'h83)); // Full: pop only.
            cycle(1'b1, 1'b0, byte'(i ^ 32'hc6));
        end
        for (int i = 0; i < 200; i++) begin
            r = 2'(next_random());
            value = byte'(next_random());
            cycle(r[0], r[1], value);
        end

        // Reset clears occupancy and both pointers, even with requests held.
        reach_count(DEPTH);
        @(negedge clk);
        push = 1'b1;
        pop = 1'b1;
        rst_n = 1'b0;
        model_q.delete();
        #1;
        check_state();
        repeat (2) @(negedge clk);
        push = 1'b0;
        pop = 1'b0;
        rst_n = 1'b1;
        #1;
        check_state();
        cycle(1'b1, 1'b0, 8'hd9);
        cycle(1'b0, 1'b1, 8'h00);

        if (accepted_pushes < 2 * DEPTH || accepted_pops < 2 * DEPTH)
            $fatal(1, "FIFO pointer wrap not exercised pushes=%0d pops=%0d",
                   accepted_pushes, accepted_pops);
        for (int state_bin = 0; state_bin < 3; state_bin++)
            for (int op = 0; op < 4; op++)
                if (coverage[state_bin][op] == 0)
                    $fatal(1, "FIFO coverage missing state=%0d op=%0d", state_bin, op);
        $display("COVERAGE fifo cycles=%0d pushes=%0d pops=%0d depth=%0d",
                 cycles, accepted_pushes, accepted_pops, DEPTH);
        for (int state_bin = 0; state_bin < 3; state_bin++)
            for (int op = 0; op < 4; op++)
                $display("COVERAGE fifo state=%0d push=%0d pop=%0d count=%0d",
                         state_bin, (op >> 1) & 1, op & 1, coverage[state_bin][op]);
        $display("FIFO_TEST_PASS cycles=%0d pushes=%0d pops=%0d depth=%0d",
                 cycles, accepted_pushes, accepted_pops, DEPTH);
        $finish;
    end
endmodule
