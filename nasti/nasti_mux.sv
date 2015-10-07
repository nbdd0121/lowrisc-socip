// See LICENSE for license details.

// up to 8 slave ports
module nasti_mux
  #(
    W_MAX = 2,                  // maximal parallel write transactions
    R_MAX = 2,                  // maximal parallel read transactions
    ID_WIDTH = 1,               // id width
    ADDR_WIDTH = 8,             // address width
    DATA_WIDTH = 8,             // width of data
    USER_WIDTH = 1              // width of user field, must > 0, let synthesizer trim it if not in use
    )
   (
    input clk, rstn,
    nasti_channel.slave  s,
    nasti_channel.master m,
    );

   // dummy
   genvar i;
   int    n;

   // transaction records
   typedef struct {
      logic [ID_WIDTH-1:0] id;
      logic [2:0]          port;
      logic                valid;
   } transaction_t;

   transaction_t [W_MAX] write_vec;
   transaction_t [R_MAX] read_vec;

   logic [$clog2(W_MAX)-1:0] write_wp;
   logic [$clog2(R_MAX)-1:0] read_wp;
   logic write_full, read_full;

   function logic is_write_full();
      int i;
      for(i=0; i<W_MAX; i++)
        if(!write_vec[i].valid)
          return 0;
      return 1;
   endfunction // is_write_full
   assign write_full = is_write_full();

   function logic is_read_full();
      int i;
      for(i=0; i<R_MAX; i++)
        if(!read_vec[i].valid)
          return 0;
      return 1;
   endfunction // is_read_full
   assign read_full = is_read_full();

   function logic[$clog2(W_MAX)-1:0] get_write_wp();
      int i;
      for(i=0; i<W_MAX; i++)
        if(!write_vec[i].valid)
          return i;
      return 0;
   endfunction //
   assign write_wp = get_write_wp();

   function logic[$clog2(R_MAX)-1:0] get_read_wp();
      int i;
      for(i=0; i<R_MAX; i++)
        if(!read_vec[i].valid)
          return i;
      return 0;
   endfunction //
   assign read_wp = get_read_wp();

   function logic [2:0] toInt (logic [7:0] dat);
      int i;
      for(i=0; i<8; i++)
        if(dat[i]) return i;
      return 0;
   endfunction // toInt
      
   // AW/W/B channels
   logic       lock;
   logic [2:0] locked_port;
   logic [2:0] aw_port_sel;
   logic [7:0] aw_gnt;

   arbiter_rr #(8)
   aw_arb (
           .*,
           .req    ( s.aw_valid           ),
           .gnt    ( aw_gnt               ),
           .enable ( !lock && !write_full )
           );

   assign aw_port_sel = lock ? locked_port : toInt(aw_gnt);

   always_ff @(posedge clk or negedge rstn)
     if(!rstn)
       lock <= 1'b0;
     else if(s.aw_valid[aw_port_sel] && s.aw_ready[aw_port_sel]) begin
        lock <= 1'b1;
        locked_port <= aw_port_sel;
     end else if(s.w_last[aw_port_sel] && s.w_valid[aw_port_sel] && s.w_ready[aw_port_sel])
       lock <= 1'b0;

   assign m.aw_id      = s.aw_id[aw_port_sel];
   assign m.aw_addr    = s.aw_addr[aw_port_sel];
   assign m.aw_len     = s.aw_len[aw_port_sel];
   assign m.aw_size    = s.aw_size[aw_port_sel];
   assign m.aw_burst   = s.aw_burst[aw_port_sel];
   assign m.aw_lock    = s.aw_lock[aw_port_sel];
   assign m.aw_cache   = s.aw_cache[aw_port_sel];
   assign m.aw_prot    = s.aw_prot[aw_port_sel];
   assign m.aw_qos     = s.aw_qos[aw_port_sel];
   assign m.aw_region  = s.aw_region[aw_port_sel];
   assign m.aw_user    = s.aw_user[aw_port_sel];
   assign m.aw_valid   = !lock && s.aw_valid[aw_port_sel];
   assign m.w_data     = s.w_data[aw_port_sel];
   assign m.w_strb     = s.w_strb[aw_port_sel];
   assign m.w_last     = s.w_last[aw_port_sel];
   assign m.w_user     = s.w_user[aw_port_sel];
   assign m.w_valid    = lock && s.w_valid[aw_port_sel];
   assign s.aw_ready   = m.aw_ready ? (1 << aw_port_sel) : 0;
   assign s.w_ready    = m.w_ready ? (1 << aw_port_sel) : 0;

   logic [$clog2(W_MAX)-1:0] write_matched;

   always_comb @(*) begin
      write_matched = 0;
      for(n=0; n<W_MAX; n++)
        write_matched = write_matched | (write_vec[n].valid && m.b_id == write_vec[n].id ? n : 0);
   end

   generate
      for(i=0; i<8; i++) begin
         assign s.b_id[i]    = m.b_id;
         assign s.b_resp[i]  = m.b_resp;
         assign s.b_user[i]  = m.b_user;
         assign s.b_valid[i] = m.b_valid && write_vec[write_matched].port == i;
      end
   endgenerate
   assign m.b_ready = s.b_ready[write_vec[write_matched].port];

   // update write_vec
   always_ff @(posedge clk or negedge rstn)
     if(!rstn) begin
        for(n=0; n<W_MAX; n++)
          write_vec.valid <= 0;
     end else begin
        if(m.aw_valid && m.aw_ready)
          write_vec[write_wp] <= {m.aw_id, aw_port_sel, 1};

        if(m.b_valid && m.b_ready)
          write_vec[write_matched].valid <= 0;
     end

   // AR and R
   logic [2:0] ar_port_sel;
   logic [7:0] ar_gnt;

   arbiter_rr #(8)
   ar_arb (
           .*,
           .req    ( s.ar_valid  ),
           .gnt    ( ar_gnt      ),
           .enable ( !read_full  )
           );
   assign ar_port_sel = toInt(ar_gnt);

   assign m.ar_id      = s.ar_id[ar_port_sel];
   assign m.ar_addr    = s.ar_addr[ar_port_sel];
   assign m.ar_len     = s.ar_len[ar_port_sel];
   assign m.ar_size    = s.ar_size[ar_port_sel];
   assign m.ar_burst   = s.ar_burst[ar_port_sel];
   assign m.ar_lock    = s.ar_lock[ar_port_sel];
   assign m.ar_cache   = s.ar_cache[ar_port_sel];
   assign m.ar_prot    = s.ar_prot[ar_port_sel];
   assign m.ar_qos     = s.ar_qos[ar_port_sel];
   assign m.ar_region  = s.ar_region[ar_port_sel];
   assign m.ar_user    = s.ar_user[ar_port_sel];
   assign m.ar_valid   = s.ar_valid[ar_port_sel];
   assign s_ar.ready   = m.ar_ready ? (1 << ar_port_sel) : 0;

   logic [$clog2(R_MAX)-1:0] read_matched;

   always_comb @(*) begin
      read_matched = 0;
      for(n=0; n<R_MAX; n++)
        read_matched = read_matched | (read_vec[n].valid && m.r_id == read_vec[n].id ? n : 0);
   end

   generate
      for(i=0; i<8; i++) begin
         assign s.r_id[i]    = m.r_id;
         assign s.r_data[i]  = m.r_data;
         assign s.r_resp[i]  = m.r_resp;
         assign s.r_last[i]  = m.r_last;
         assign s.r_user[i]  = m.r_user;
         assign s.r_valid[i] = m.r_valid && read_vec[read_matched].port == i;
      end
   endgenerate
   assign m.r_ready = s.r_ready[read_vec[read_matched].port];

   // update read_vec
   always_ff @(posedge clk or negedge rstn)
     if(!rstn) begin
        for(n=0; n<R_MAX; n++)
          read_vec.valid <= 0;
     end else begin
        if(m.ar_valid && m.ar_ready)
          read_vec[read_wp] <= {m.ar_id, ar_port_sel, 1};

        if(m.r_valid && m.r_ready)
          read_vec[read_matched].valid <= 0;
     end

endmodule // nasti_mux
