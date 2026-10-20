/*
 * rv32im_driver.sv — UVM driver for RV32IM DUT
 *
 * Implements the ibex OBI instruction-fetch and data-memory protocols.
 * Maintains a local instruction-memory model (imem_q) and data-memory
 * model (dmem_q).  Configurable grant latency per transaction.
 *
 * Protocol (ibex OBI):
 *   - req asserted by DUT
 *   - TB asserts gnt 0–3 cycles later (latency from mem_latency field)
 *   - rvalid asserted one cycle after gnt (registered response)
 *   - rdata valid when rvalid = 1
 */

`ifndef RV32IM_DRIVER_SV
`define RV32IM_DRIVER_SV

class rv32im_driver extends uvm_driver #(rv32im_txn);
  `uvm_component_utils(rv32im_driver)

  /* Virtual interface handle */
  virtual rv32im_if.driver_mp vif;

  /* Local memory models */
  /* 256 KB, word-addressed internally */
  logic [31:0] imem_q [0 : 65535];   /* 64K x 32 = 256KB */
  logic [31:0] dmem_q [0 : 65535];

  /* Instruction queue: sequences load instructions here before
   * the DUT starts fetching.  Index = word address (addr >> 2). */
  int unsigned instr_count;   /* total instructions loaded */
  int unsigned next_load_addr;/* byte address for next load */

  function new(string name = "rv32im_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual rv32im_if)::get(this, "", "vif", vif))
      `uvm_fatal("DRIVER", "No virtual interface rv32im_if found in config_db")
    /* Zero memories */
    foreach (imem_q[i]) imem_q[i] = 32'h0000_0013; /* ADDI x0,x0,0 (NOP) */
    foreach (dmem_q[i]) dmem_q[i] = 32'h0;
    instr_count     = 0;
    next_load_addr  = 0;
  endfunction

  /* ----------------------------------------------------------------
   * run_phase: drive reset then process sequence items
   * ----------------------------------------------------------------*/
  task run_phase(uvm_phase phase);
    drive_reset();

    forever begin
      rv32im_txn txn;
      seq_item_port.get_next_item(txn);
      drive_instr(txn);
      seq_item_port.item_done();
    end
  endtask

  /* ----------------------------------------------------------------
   * drive_reset: hold all driven signals at safe values for 10 cycles
   * ----------------------------------------------------------------*/
  task drive_reset();
    vif.drv_cb.instr_gnt_i    <= 0;
    vif.drv_cb.instr_rvalid_i <= 0;
    vif.drv_cb.instr_rdata_i  <= 32'h0;
    vif.drv_cb.instr_err_i    <= 0;
    vif.drv_cb.data_gnt_i     <= 0;
    vif.drv_cb.data_rvalid_i  <= 0;
    vif.drv_cb.data_rdata_i   <= 32'h0;
    vif.drv_cb.data_err_i     <= 0;
    vif.drv_cb.irq_fast_i     <= 15'h0;
    vif.drv_cb.irq_nm_i       <= 0;
    repeat (10) @(vif.drv_cb);
  endtask

  /* ----------------------------------------------------------------
   * drive_instr: load one instruction into imem and sync ISS
   * ----------------------------------------------------------------*/
  task drive_instr(rv32im_txn txn);
    int unsigned word_addr;

    /* Load instruction into local imem */
    word_addr = next_load_addr >> 2;
    if (word_addr < 65536) begin
      imem_q[word_addr] = txn.instr;
      /* Sync to ISS imem via DPI */
      iss_dpi_write_instr(next_load_addr, txn.instr);
    end

    /* Preload rs1/rs2 values into dmem if sequence requests it
     * (used by hazard sequences to control operand values) */
    /* (sequences set rs1_val/rs2_val; driver ignores here —
     *  register preload is done by a directed setup sequence) */

    next_load_addr += 4;
    instr_count++;

    /* Now handle any pending instruction-fetch requests.
     * The DUT may or may not have already started fetching. */
    handle_fetch_requests(txn.mem_latency);
  endtask

  /* ----------------------------------------------------------------
   * handle_fetch_requests: respond to OBI instruction fetch
   * ----------------------------------------------------------------*/
  task handle_fetch_requests(int unsigned latency);
    /* Wait up to 200 cycles for DUT to make a fetch request */
    int timeout = 200;
    while (timeout-- > 0) begin
      @(vif.drv_cb);
      if (vif.drv_cb.instr_req_o) begin
        respond_to_fetch(latency);
        return;
      end
    end
    `uvm_warning("DRIVER", "No instr_req seen within 200 cycles")
  endtask

  task respond_to_fetch(int unsigned latency);
    int unsigned addr;
    int unsigned word_addr;
    logic [31:0] rdata;

    /* Apply configured grant latency */
    repeat (latency) @(vif.drv_cb);

    /* Grant */
    addr      = vif.drv_cb.instr_addr_o;
    word_addr = addr >> 2;
    rdata     = (word_addr < 65536) ? imem_q[word_addr] : 32'h0000_0013;

    vif.drv_cb.instr_gnt_i <= 1;
    @(vif.drv_cb);
    vif.drv_cb.instr_gnt_i <= 0;

    /* rvalid one cycle after gnt */
    vif.drv_cb.instr_rvalid_i <= 1;
    vif.drv_cb.instr_rdata_i  <= rdata;
    @(vif.drv_cb);
    vif.drv_cb.instr_rvalid_i <= 0;

    /* Handle concurrent data memory request if any */
    if (vif.drv_cb.data_req_o)
      respond_to_data_req();
  endtask

  /* ----------------------------------------------------------------
   * respond_to_data_req: handle a data memory transaction
   * ----------------------------------------------------------------*/
  task respond_to_data_req();
    int unsigned addr     = vif.drv_cb.data_addr_o;
    logic        we       = vif.drv_cb.data_we_o;
    logic [3:0]  be       = vif.drv_cb.data_be_o;
    logic [31:0] wdata    = vif.drv_cb.data_wdata_o;
    int unsigned word_addr = addr >> 2;
    logic [31:0] rdata;

    /* Immediate grant for data port */
    vif.drv_cb.data_gnt_i <= 1;
    @(vif.drv_cb);
    vif.drv_cb.data_gnt_i <= 0;

    if (we) begin
      /* Write: apply byte enables */
      if (word_addr < 65536) begin
        if (be[0]) dmem_q[word_addr][ 7: 0] = wdata[ 7: 0];
        if (be[1]) dmem_q[word_addr][15: 8] = wdata[15: 8];
        if (be[2]) dmem_q[word_addr][23:16] = wdata[23:16];
        if (be[3]) dmem_q[word_addr][31:24] = wdata[31:24];
      end
      vif.drv_cb.data_rvalid_i <= 1;
      vif.drv_cb.data_rdata_i  <= 32'h0;
    end else begin
      /* Read */
      rdata = (word_addr < 65536) ? dmem_q[word_addr] : 32'h0;
      vif.drv_cb.data_rvalid_i <= 1;
      vif.drv_cb.data_rdata_i  <= rdata;
    end

    @(vif.drv_cb);
    vif.drv_cb.data_rvalid_i <= 0;
  endtask

  /* ----------------------------------------------------------------
   * Helper: write a word directly to driver dmem (called by tests)
   * ----------------------------------------------------------------*/
  function void write_dmem(int unsigned byte_addr, logic [31:0] data);
    int unsigned widx = byte_addr >> 2;
    if (widx < 65536) dmem_q[widx] = data;
  endfunction

endclass : rv32im_driver

`endif // RV32IM_DRIVER_SV
