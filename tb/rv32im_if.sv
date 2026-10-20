/*
 * rv32im_if.sv — SystemVerilog interface for ibex RV32IM DUT
 *
 * Captures all signals between the testbench and DUT.
 * Passed via uvm_config_db#(virtual rv32im_if) to driver/monitor.
 */

`ifndef RV32IM_IF_SV
`define RV32IM_IF_SV

interface rv32im_if (
  input logic clk,
  input logic rst_n
);

  /* ------------------------------------------------------------------
   * Instruction fetch port (ibex OBI protocol)
   * ----------------------------------------------------------------*/
  logic        instr_req_o;      /* DUT requests instruction fetch      */
  logic        instr_gnt_i;      /* TB grants the request               */
  logic        instr_rvalid_i;   /* TB: instruction data is valid       */
  logic [31:0] instr_addr_o;     /* DUT: fetch address                  */
  logic [31:0] instr_rdata_i;    /* TB: instruction word                */
  logic        instr_err_i;      /* TB: bus error (tie 0 normally)      */

  /* ------------------------------------------------------------------
   * Data memory port (ibex OBI protocol)
   * ----------------------------------------------------------------*/
  logic        data_req_o;
  logic        data_gnt_i;
  logic        data_rvalid_i;
  logic        data_we_o;        /* 1 = write, 0 = read                 */
  logic [3:0]  data_be_o;        /* byte enables                        */
  logic [31:0] data_addr_o;
  logic [31:0] data_wdata_o;
  logic [31:0] data_rdata_i;
  logic        data_err_i;

  /* ------------------------------------------------------------------
   * Interrupt / debug inputs (tie unused ones to 0)
   * ----------------------------------------------------------------*/
  logic [14:0] irq_fast_i;
  logic        irq_nm_i;

  /* ------------------------------------------------------------------
   * Commit / writeback observation port
   * Ibex exposes these via the register file write port —
   * we tap them here for the monitor.
   * ----------------------------------------------------------------*/
  logic        commit_valid;    /* high when a result is committed     */
  logic [4:0]  commit_rd;       /* destination register                */
  logic [31:0] commit_result;   /* value written to rd                 */
  logic [31:0] commit_pc;       /* PC of committed instruction         */
  logic [31:0] commit_instr;    /* raw instruction word                */

  /* ------------------------------------------------------------------
   * Exception / CSR observation
   * ----------------------------------------------------------------*/
  logic        trap_valid;      /* exception taken this cycle          */
  logic [31:0] trap_cause;      /* mcause value                        */
  logic [31:0] trap_pc;         /* mepc value                          */

  /* ------------------------------------------------------------------
   * Clocking blocks
   * ----------------------------------------------------------------*/

  /* Driver drives: instr_gnt_i, instr_rvalid_i, instr_rdata_i,
   *                data_gnt_i,  data_rvalid_i,  data_rdata_i  */
  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    /* inputs from DUT (driver observes) */
    input  instr_req_o;
    input  instr_addr_o;
    input  data_req_o;
    input  data_we_o;
    input  data_be_o;
    input  data_addr_o;
    input  data_wdata_o;
    /* outputs to DUT (driver drives) */
    output instr_gnt_i;
    output instr_rvalid_i;
    output instr_rdata_i;
    output instr_err_i;
    output data_gnt_i;
    output data_rvalid_i;
    output data_rdata_i;
    output data_err_i;
    output irq_fast_i;
    output irq_nm_i;
  endclocking

  /* Monitor samples: all DUT-driven signals + commit/trap ports */
  clocking mon_cb @(posedge clk);
    default input #1step;
    input instr_req_o;
    input instr_addr_o;
    input data_req_o;
    input data_we_o;
    input data_addr_o;
    input data_wdata_o;
    input commit_valid;
    input commit_rd;
    input commit_result;
    input commit_pc;
    input commit_instr;
    input trap_valid;
    input trap_cause;
    input trap_pc;
  endclocking

  /* ------------------------------------------------------------------
   * Modports
   * ----------------------------------------------------------------*/
  modport driver_mp  (clocking drv_cb, input clk, rst_n);
  modport monitor_mp (clocking mon_cb, input clk, rst_n);
  modport dut_mp     (
    output instr_req_o,
    input  instr_gnt_i, instr_rvalid_i, instr_rdata_i, instr_err_i,
    output instr_addr_o,
    output data_req_o,
    input  data_gnt_i, data_rvalid_i, data_rdata_i, data_err_i,
    output data_we_o, data_be_o, data_addr_o, data_wdata_o,
    input  irq_fast_i, irq_nm_i
  );

  /* ------------------------------------------------------------------
   * Assertions — interface-level sanity checks
   * ----------------------------------------------------------------*/

  // instr_addr must be 4-byte aligned
  property p_instr_aligned;
    @(posedge clk) disable iff (!rst_n)
    instr_req_o |-> (instr_addr_o[1:0] == 2'b00);
  endproperty
  ap_instr_aligned: assert property (p_instr_aligned)
    else $error("[IF] Unaligned instruction fetch at addr=%08h", instr_addr_o);

  // No new req while waiting for grant (OBI rule)
  property p_no_req_change;
    @(posedge clk) disable iff (!rst_n)
    (instr_req_o && !instr_gnt_i) |=> instr_req_o;
  endproperty
  ap_no_req_change: assert property (p_no_req_change)
    else $error("[IF] instr_req deasserted before grant");

endinterface : rv32im_if

`endif // RV32IM_IF_SV
