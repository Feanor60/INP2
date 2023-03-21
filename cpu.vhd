-- cpu.vhd: Simple 8-bit CPU (BrainF*ck interpreter)
-- Copyright (C) 2020 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): Vojtìch Bùbela <xbubel08>
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru
 
   -- synchronni pamet ROM
   CODE_ADDR : out std_logic_vector(11 downto 0); -- adresa do pameti
   CODE_DATA : in std_logic_vector(7 downto 0);   -- CODE_DATA <- rom[CODE_ADDR] pokud CODE_EN='1'
   CODE_EN   : out std_logic;                     -- povoleni cinnosti
   
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(9 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- ram[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_WE    : out std_logic;                    -- cteni (0) / zapis (1)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti 
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   OUT_WE   : out std_logic                       -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'
 );
end cpu;


-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is

 -- zde dopiste potrebne deklarace signalu

 -- PC - ukazatel do pameti programu

	signal pc_reg : std_logic_vector (11 downto 0); -- hodnota v registru
	signal pc_inc : std_logic;		       -- priznak zvyseni 
	signal pc_dec : std_logic;		       -- priznak snizeni
	signal pc_ld  : std_logic;		       -- 

-- PTR - ukazatel do pameti dat
	
	signal ptr_reg : std_logic_vector (9 downto 0);
	signal ptr_inc : std_logic;
	signal ptr_dec : std_logic;

-- RAS 

	signal ras_reg : std_logic_vector (11 downto 0); -- ras registr
	signal ras_push : std_logic; 			-- priznak push
	signal ras_pop : std_logic;

-- FSM states

	type fsm_state is (
		state_default,
		state_decode,
		state_fetch,

		state_inc_ptr, 		-- >
		state_dec_ptr, 		-- <
		state_inc_val, 		-- +
		state_inc_load, 	-- konecny stav po inc/dec val
		state_dec_val,		-- -

		state_start_loop, 	-- [
		state_loop_check,       -- zkontroluj jestli byla splnena podminka ukonceni cyklu
		state_in_loop,		-- dokud jsme v cyklu
		state_in_loop_2,
		state_end_loop, 	-- ]
		state_end_loop_2,

		state_print, 		-- .
		state_end_print,	-- cyckli dokud nemuzes zapsat na output

		state_read, 		-- ,
		state_end_read,		-- cykli dokud nedostanes platna data
		state_end,		-- null

		state_mx_inc,		-- zvetsi hodnotu ktera jde pres mx
		state_mx_dec,		-- zmensi hodnotu ktera jde pres mx

		state_others
	);	

	signal state : fsm_state := state_default;
	signal nextstate : fsm_state;

-- multiplexor

	signal mx_out : std_logic_vector ( 7 downto 0 );
	signal mx_sel : std_logic_vector ( 1 downto 0 ) := "11";

begin

-- pc 	
	pc: process (CLK, RESET, pc_inc, pc_dec, pc_ld) is
	begin
		if (RESET = '1') then
			pc_reg <= (others => '0');
		elsif (CLK'event) and (CLK = '1') then
			if ( pc_inc = '1') then 
				pc_reg <= pc_reg + 1;
			elsif ( pc_dec = '1') then
				pc_reg <= pc_reg - 1;
			elsif ( pc_ld = '1' ) then
				pc_reg <= ras_reg;
			end if;
		end if;
	end process;
	CODE_ADDR  <= pc_reg;

-- ptr
	ptr: process (CLK, RESET, ptr_inc, ptr_dec) is
	begin
		if (RESET = '1') then
			ptr_reg <= (others => '0');
		elsif (CLK'event) and (CLK = '1') then
			if ( ptr_inc = '1') then 
				ptr_reg <= ptr_reg + 1;
			elsif ( ptr_dec = '1') then
				ptr_reg <= ptr_reg - 1;
			end if;
		end if;
	end process;
	DATA_ADDR <= ptr_reg;

-- mx 
	mx : process (CLK, RESET, mx_sel) is
	begin
		if (RESET = '1') then
			mx_out <= (others => '0');
		elsif (CLK'event) and (CLK = '1') then
			case mx_sel is 
				when "10" => mx_out <= DATA_RDATA + 1;
				when "01" => mx_out <= DATA_RDATA - 1;
				when "11" => mx_out <= IN_DATA;
			       	when others => mx_out <= (others => '0');
			end case;
		end if;	
	end process;
	DATA_WDATA <= mx_out;

-- konecny automat

	state_logic: process (CLK, RESET, EN) is 
	begin
		if (RESET = '1') then
			state <= state_default;
		elsif (CLK'event) and (CLK = '1') then
			if (EN = '1') then
				state <= nextstate;
			end if;
		end if;
	end process;

	fsm: process (state, IN_VLD, CODE_DATA, OUT_BUSY, DATA_RDATA) is
	begin
		pc_inc <= '0';
		pc_dec <= '0';
		pc_ld <= '0';
		ptr_inc <= '0';
		ptr_dec <= '0';
		ras_push <= '0';
		ras_pop <= '0';

		CODE_EN <= '0';
		DATA_WE <= '0';
		DATA_EN <= '0';
		IN_REQ <= '0';
		OUT_WE <= '0';

		MX_SEL <= "00";

-- FSM states

--	type fsm_state is (
--		state_default.
--		state_decode.
--		state_fetch
--
--		state_inc_ptr. 		-- >
--		state_dec_ptr. 		-- <
--		state_inc_val. 		-- +
--		state_dec_val. 		-- -
--		state_start_loop. 	-- [
--		state_end_loop. 	-- ]
--		state_print. 		-- .
--		state_read. 		-- ,
--		state_end.		-- null
--	)

		case state is 
			when state_default => nextstate <= state_fetch;
		       
			-- nacti dalsi instrukci
			when state_fetch => CODE_EN <= '1'; 
		       		            nextstate <= state_decode;
			
			-- dekoduj nactenou instrukci
			when state_decode => 
				case CODE_DATA is 
					when X"3E" => nextstate <= state_inc_ptr;
					when X"3C" => nextstate <= state_dec_ptr;
					when X"2B" => nextstate <= state_inc_val;
					when X"2D" => nextstate <= state_dec_val;
					when X"5B" => nextstate <= state_start_loop;
					when X"5D" => nextstate <= state_end_loop;
					when X"2E" => nextstate <= state_print;
					when X"2C" => nextstate <= state_read;
					when X"00" => nextstate <= state_end;
					when others => nextstate <= state_others;
				end case;

		-- >	
			when state_inc_ptr => pc_inc <= '1';
		       			      ptr_inc <= '1';
					      nextstate <= state_fetch;
			
		-- <
			when state_dec_ptr => pc_inc <= '1';
		       		              ptr_dec <= '1';
					      nextstate <= state_fetch;
		
		-- +			      
			when state_inc_val => DATA_EN <= '1';
		       			      DATA_WE <= '0';
					      nextstate <= state_mx_inc;

			when state_mx_inc => mx_sel <= "10";
		       		 	     nextstate <= state_inc_load;

		-- -			     
			when state_dec_val => DATA_EN <= '1'; 
					      DATA_WE <= '0';
					      nextstate <= state_mx_dec;

			when state_mx_dec =>  mx_sel <= "01";
		       			      nextstate <= state_inc_load;

		-- navrat do stavu fetch po +/-			      
			when state_inc_load => DATA_EN <= '1';
					       DATA_WE <= '1';
					       pc_inc <= '1';
					       nextstate <= state_fetch;

		-- [
			when state_start_loop =>
				pc_inc <= '1';
				DATA_EN <= '1';
				DATA_WE <= '0';
				nextstate <= state_loop_check;

			when state_loop_check =>
				if (DATA_RDATA /= (DATA_RDATA'range => '0')) then -- RDATA nejsou 0
					ras_reg <= pc_reg; -- ulozim si pozici zacatku while loopu
					nextstate <= state_fetch;
				else
					CODE_EN <= '1';
					nextstate <= state_in_loop;
				end if;

			when state_in_loop =>
				pc_inc <= '1';
				if (CODE_DATA = X"5D") then
					ras_reg <= (others => '0');
					nextstate <= state_fetch;
				else
					nextstate <= state_in_loop;
				end if;

			when state_in_loop_2 =>
				CODE_EN <= '1';

				nextstate <= state_in_loop_2;
		
		-- ]

			when state_end_loop =>
				DATA_EN <= '1';
				DATA_WE <= '0';

				nextstate <= state_end_loop_2;	
			when state_end_loop_2 =>
				if (DATA_RDATA /= (DATA_RDATA'range => '0')) then -- zkontrolovat jestli je ram[PTR] == NULL
					pc_ld <= '1'; -- pokud podminka neplati tak se vratime na zacatek zyklu
					nextstate <= state_fetch;
				else 
					pc_inc <= '1';
					ras_reg <= (others => '0');
					nextstate <= state_fetch;
				end if;
				
		-- .	
			when state_print => DATA_WE <= '0';
					    DATA_EN <= '1';
					    nextstate <= state_end_print;

			when state_end_print => 
				if (OUT_BUSY = '1') then -- while (OUT_BUSY)
					DATA_WE <= '0';
					DATA_EN <= '1';
					nextstate <= state_end_print;
				else
					OUT_WE  <= '1';
					pc_inc <= '1';
					OUT_DATA <= DATA_RDATA;
					nextstate <= state_fetch;
				end if;

		-- ;		
			when state_read =>
			       	IN_REQ <= '1';
				mx_sel <= "11";
             		        nextstate <= state_end_read;

			when state_end_read => 
				if ( IN_VLD /= '1') then -- pokud precteme neplatne data - while (!IN_VLD)
					mx_sel <= "11";	 -- multiplexor nastaveny na cteni
					IN_REQ <= '1';	 -- ocekava se vstup
					nextstate <= state_end_read;	-- vratime se znovu na tento stav
				else -- pokud byly precteny platne data
					DATA_EN <= '1'; -- nyni muzeme pracovat s pameti
					DATA_WE <= '1'; -- nyni muzeme zapisovat do pameti
					pc_inc <= '1'; -- zvysi se program counter
					nextstate <= state_fetch; -- vrat se do cteciho stavu
				end if;
			when state_end =>
				nextstate <= state_end;

			when state_others =>
				pc_inc <= '1';
			       	nextstate <= state_fetch;

			when others => null;

		end case;	

	end process;
	
	next_sate_logic: process (RESET, CLK, EN) is 
	begin


	end process;

 -- zde dopiste vlastni VHDL kod


 -- pri tvorbe kodu reflektujte rady ze cviceni INP, zejmena mejte na pameti, ze 
 --   - nelze z vice procesu ovladat stejny signal,
 --   - je vhodne mit jeden proces pro popis jedne hardwarove komponenty, protoze pak
 --   - u synchronnich komponent obsahuje sensitivity list pouze CLK a RESET a 
 --   - u kombinacnich komponent obsahuje sensitivity list vsechny ctene signaly.
 
end behavioral;
 
