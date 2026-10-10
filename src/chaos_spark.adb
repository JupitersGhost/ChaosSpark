with Ada.Calendar;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;
with Interfaces.C;
with GNAT.Sockets;

with Chaos_CHVS;
with Chaos_Stats;
with Chaos_Types;

procedure Chaos_Spark
  with SPARK_Mode => Off
is
   use Ada.Strings.Unbounded;
   use Chaos_CHVS;
   use Chaos_Stats;
   use Chaos_Types;

   use type Byte;
   use type U32;
   use type U64;
   use type Ada.Calendar.Time;
   use type Ada.Streams.Stream_Element_Offset;

   package C renames Interfaces.C;
   package SIO renames Ada.Streams.Stream_IO;
   package Net renames GNAT.Sockets;

   ---------------------------------------------------------------------------
   --  Environment
   ---------------------------------------------------------------------------

   function Env
     (Name    : String;
      Default : String) return String
   is
   begin
      if Ada.Environment_Variables.Exists (Name) then
         return Ada.Environment_Variables.Value (Name);
      else
         return Default;
      end if;
   end Env;

   State_Dir :
     constant String :=
       Env
         ("CHAOS_SPARK_STATE",
          "/var/lib/chaos-spark");

   Runtime_Dir :
     constant String :=
       Env
         ("CHAOS_SPARK_RUNTIME",
          "/run/chaos-spark");

   Web_Root :
     constant String :=
       Env
         ("CHAOS_SPARK_WEB_ROOT",
          "web");

   Bind_IP :
     constant String :=
       Env
         ("CHAOS_SPARK_BIND_IP",
          "127.0.0.1");

   Peers :
     constant String :=
       Env
         ("CHAOS_SPARK_PEERS",
          "");

   --  Example Raspberry Pi 5 deployment defaults. Each value can be
   --  overridden through its corresponding environment variable.

   Chaosfield_Device :
     constant String :=
       Env
         ("CHAOS_SPARK_CHAOSFIELD",
          "/dev/chaosfield");

   Camera_Device :
     constant String :=
       Env
         ("CHAOS_SPARK_CAMERA",
          "/dev/video0");

   Audio_Device :
     constant String :=
       Env
         ("CHAOS_SPARK_AUDIO",
          "plughw:CARD=H4,DEV=0");

   Wifi_Interface :
     constant String :=
       Env
         ("CHAOS_SPARK_WIFI",
          "wlan0");

   Key_Hex :
     constant String :=
       Env
         ("CHAOS_SPARK_CHVS_KEY_HEX",
          "");

   CHVS_Key_Value :
     CHVS_Key := (others => 0);

   Key_Valid :
     constant Boolean :=
       Decode_Key
         (Key_Hex,
          CHVS_Key_Value);

   ---------------------------------------------------------------------------
   --  libc system()
   ---------------------------------------------------------------------------

   function C_System
     (Command : C.char_array) return C.int
   with
     Import,
     Convention    => C,
     External_Name => "system";

   function Run
     (Command : String) return Integer
   is
      Result :
        C.int;
   begin
      Result :=
        C_System
          (C.To_C (Command));

      return Integer (Result);
   end Run;

   ---------------------------------------------------------------------------
   --  Time
   ---------------------------------------------------------------------------

   Epoch :
     constant Ada.Calendar.Time :=
       Ada.Calendar.Time_Of
         (Year    => 1970,
          Month   => 1,
          Day     => 1,
          Seconds => 0.0);

   function Now_Ms return U64
   is
      D :
        Duration :=
          Ada.Calendar.Clock - Epoch;
   begin
      if D <= 0.0 then
         return 0;
      end if;

      return
        U64
          (Long_Long_Integer
             (D * 1_000.0));
   end Now_Ms;

   ---------------------------------------------------------------------------
   --  Files
   ---------------------------------------------------------------------------

   procedure Ensure_Runtime
   is
      Ignore :
        Integer;
   begin
      Ignore :=
        Run
          ("mkdir -p "
           & Runtime_Dir
           & " "
           & State_Dir);

      pragma Unreferenced (Ignore);
   end Ensure_Runtime;

   function Read_Text
     (Path : String) return String
   is
      File :
        SIO.File_Type;

      Buffer :
        Ada.Streams.Stream_Element_Array
          (1 .. 65_536);

      Last :
        Ada.Streams.Stream_Element_Offset;

      Result :
        Unbounded_String := Null_Unbounded_String;
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;

      SIO.Open
        (File,
         SIO.In_File,
         Path);

      loop
         SIO.Read
           (File,
            Buffer,
            Last);

         if Last >= Buffer'First then
            for I in Buffer'First .. Last loop
               Append
                 (Result,
                  Character'Val (Buffer (I)));
            end loop;
         end if;

         exit when Last < Buffer'Last;
         exit when SIO.End_Of_File (File);
      end loop;

      SIO.Close (File);

      return To_String (Result);
   exception
      when others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;

         return "";
   end Read_Text;

   ---------------------------------------------------------------------------
   --  Numeric text cleanup
   --
   --  sysfs and command output normally terminate numeric values with LF/CR.
   --  Numeric 'Value attributes reject those control characters.
   ---------------------------------------------------------------------------

   function Trim_ASCII_Whitespace
     (Input : String) return String
   is
      Result :
        Unbounded_String :=
          To_Unbounded_String (Input);

      Ch :
        Character;
   begin
      while Length (Result) > 0 loop
         Ch := Element (Result, 1);

         exit when
           Ch /= ' '
           and then Ch /= ASCII.HT
           and then Ch /= ASCII.CR
           and then Ch /= ASCII.LF;

         Delete (Result, 1, 1);
      end loop;

      while Length (Result) > 0 loop
         Ch := Element (Result, Length (Result));

         exit when
           Ch /= ' '
           and then Ch /= ASCII.HT
           and then Ch /= ASCII.CR
           and then Ch /= ASCII.LF;

         Delete
           (Result,
            Length (Result),
            Length (Result));
      end loop;

      return To_String (Result);
   end Trim_ASCII_Whitespace;

   procedure Remove_If_Exists
     (Path : String)
   is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Remove_If_Exists;

   ---------------------------------------------------------------------------
   --  Session
   ---------------------------------------------------------------------------

   function Make_Session return Session_Id
   is
      Seed :
        Byte_Array
          (1 .. CHVS_Key_Bytes + 8);

      P :
        Natural := 1;

      T :
        U64 := Now_Ms;

      D :
        Digest_512;
   begin
      for B of CHVS_Key_Value loop
         Seed (P) := B;
         P := P + 1;
      end loop;

      for Octet in reverse 0 .. 7 loop
         Seed (P) :=
           Byte
             (Interfaces.Shift_Right
                (T, Natural (Octet * 8))
              and 16#FF#);

         P := P + 1;
      end loop;

      D :=
        SHA3_512 (Seed);

      return
        Session_Id
          (D (1 .. Session_Id_Bytes));
   end Make_Session;

   Session :
     constant Session_Id :=
       Make_Session;

   Pool :
     Pool_State :=
       Initialize_Pool (Session);

   ---------------------------------------------------------------------------
   --  Sources
   ---------------------------------------------------------------------------

   Sources :
     Source_Context_Array;

   procedure Initialize_Sources
   is
   begin
      for Id in Source_Id loop
         Sources (Id) :=
           Make_Source (Id);
      end loop;
   end Initialize_Sources;

   ---------------------------------------------------------------------------
   --  Conditioned-history diagnostics
   ---------------------------------------------------------------------------

   Conditioned_History :
     Raw_Window := (others => 0);

   Conditioned_Used :
     Window_Byte_Count := 0;

   Conditioned_Metrics :
     Entropy_Metrics :=
       Zero_Metrics;

   procedure Add_Conditioned
     (Data : Digest_512)
   is
   begin
      for B of Data loop
         if Conditioned_Used < Raw_Window_Bytes then
            Conditioned_Used :=
              Conditioned_Used + 1;

            Conditioned_History
              (Conditioned_Used) := B;
         end if;

         if Conditioned_Used = Raw_Window_Bytes then
            Conditioned_Metrics :=
              Analyze
                (Conditioned_History,
                 Conditioned_Used,
                 Pi_HWRNG);

            Conditioned_History :=
              (others => 0);

            Conditioned_Used := 0;
         end if;
      end loop;
   end Add_Conditioned;

   ---------------------------------------------------------------------------
   --  Runtime counters
   ---------------------------------------------------------------------------

   Outbound_Frames :
     U64 := 0;

   Inbound_Frames :
     U64 := 0;

   Inbound_Rejected :
     U64 := 0;

   Inbound_Gaps :
     U64 := 0;

   Pending_Credited_Bits :
     U64 := 0;

   Chaosfield_Protocol_Frames :
     U64 := 0;

   Chaosfield_Status_Frames :
     U64 := 0;

   Chaosfield_Conditioned_Frames :
     U64 := 0;

   Chaosfield_Conditioned_Bytes :
     U64 := 0;

   Chaosfield_CRC_Failures :
     U64 := 0;

   Chaosfield_Malformed_Frames :
     U64 := 0;

   Chaosfield_Nonprotocol_Lines :
     U64 := 0;

   Chaosfield_Sequence_Gaps :
     U64 := 0;

   Chaosfield_Replays :
     U64 := 0;

   Chaosfield_Rejected_Bytes :
     U64 := 0;

   Chaosfield_Last_Session :
     String (1 .. 32) := (others => '0');

   Chaosfield_Last_Sequence :
     U64 := 0;

   Chaosfield_Have_Sequence :
     Boolean := False;

   Chaosfield_Last_Protocol_Ms :
     U64 := 0;

   Chaosfield_Last_Mix_Ms :
     U64 := 0;

   Chaosfield_Line_Buffer :
     Unbounded_String := Null_Unbounded_String;

   Chaosfield_Discarding_Line :
     Boolean := False;

   Remote_Frames_Mixed :
     U64 := 0;

   Remote_Bytes_Mixed :
     U64 := 0;

   Last_Remote_Session :
     Session_Id := (others => 0);

   Last_Remote_Sequence :
     U64 := 0;

   Last_Remote_Source_Bitmap :
     U32 := 0;

   Last_Remote_Healthy_Bitmap :
     U32 := 0;

   Last_Remote_Origin_Credit :
     U32 := 0;

   Wifi_Motion_Score :
     Natural := 0;

   Last_RSSI :
     Integer := -127;

   ---------------------------------------------------------------------------
   --  Incoming remote contribution slot
   ---------------------------------------------------------------------------

   protected Inbox is
      procedure Put
        (Payload : CHVS_Payload);

      procedure Take
        (Available : out Boolean;
         Payload   : out CHVS_Payload);
   private
      Pending :
        Boolean := False;

      Item :
        CHVS_Payload :=
          (Header => (others => <>),
           Data   => (others => 0));
   end Inbox;

   protected body Inbox is

      procedure Put
        (Payload : CHVS_Payload)
      is
      begin
         Item := Payload;
         Pending := True;
      end Put;

      procedure Take
        (Available : out Boolean;
         Payload   : out CHVS_Payload)
      is
      begin
         Available := Pending;
         Payload := Item;

         if Pending then
            Pending := False;
         end if;
      end Take;

   end Inbox;

   ---------------------------------------------------------------------------
   --  Networking helpers
   ---------------------------------------------------------------------------

   function Peer_Host
     (Token : String) return String
   is
      Clean :
        constant String :=
          Ada.Strings.Fixed.Trim
            (Token,
             Ada.Strings.Both);

      Colon :
        Natural := 0;
   begin
      if Clean'Length = 0 then
         return "";
      end if;

      for I in Clean'Range loop
         if Clean (I) = ':' then
            Colon := I;
            exit;
         end if;
      end loop;

      if Colon = 0 then
         return Clean;
      elsif Colon = Clean'First then
         return "";
      else
         return Clean (Clean'First .. Colon - 1);
      end if;
   end Peer_Host;

   function Explicit_Peer_IP
     (IP : String) return Boolean
   is
      Start :
        Natural;

      Stop :
        Natural;

      I :
        Natural;
   begin
      if Peers'Length = 0 then
         return False;
      end if;

      Start := Peers'First;
      I := Start;

      while I <= Peers'Last + 1 loop
         if I > Peers'Last
           or else Peers (I) = ','
         then
            Stop := I - 1;

            if Stop >= Start then
               declare
                  Host :
                    constant String :=
                      Peer_Host
                        (Peers (Start .. Stop));
               begin
                  if Host = IP then
                     return True;
                  end if;
               end;
            end if;

            Start := I + 1;
         end if;

         I := I + 1;
      end loop;

      return False;
   end Explicit_Peer_IP;

   function Allowed_IP
     (IP : String) return Boolean
   is
   begin
      return
        Is_Private_Overlay_IP (IP)
        or else Explicit_Peer_IP (IP)
        or else
        (Bind_IP = "127.0.0.1"
         and then IP = "127.0.0.1");
   end Allowed_IP;

   function To_Stream
     (Frame : Wire_Frame)
      return Ada.Streams.Stream_Element_Array
   is
      Result :
        Ada.Streams.Stream_Element_Array
          (1 ..
             Ada.Streams.Stream_Element_Offset
               (Wire_Frame_Bytes));
   begin
      for I in Frame'Range loop
         Result
           (Ada.Streams.Stream_Element_Offset (I)) :=
             Ada.Streams.Stream_Element
               (Frame (I));
      end loop;

      return Result;
   end To_Stream;

   function From_Stream
     (Data : Ada.Streams.Stream_Element_Array)
      return Wire_Frame
   is
      Result :
        Wire_Frame := (others => 0);
   begin
      for I in Result'Range loop
         Result (I) :=
           Byte
             (Data
                (Ada.Streams.Stream_Element_Offset (I)));
      end loop;

      return Result;
   end From_Stream;

   procedure Send_All
     (Socket : Net.Socket_Type;
      Data   : Ada.Streams.Stream_Element_Array)
   is
      First :
        Ada.Streams.Stream_Element_Offset :=
          Data'First;

      Last :
        Ada.Streams.Stream_Element_Offset;
   begin
      while First <= Data'Last loop
         Net.Send_Socket
           (Socket,
            Data (First .. Data'Last),
            Last);

         exit when Last < First;

         First := Last + 1;
      end loop;
   end Send_All;

   ---------------------------------------------------------------------------
   --  CHVS receiver
   ---------------------------------------------------------------------------

   task CHVS_Receiver;

   task body CHVS_Receiver
   is
      Server :
        Net.Socket_Type;

      Client :
        Net.Socket_Type;

      Server_Address :
        Net.Sock_Addr_Type;

      Peer_Address :
        Net.Sock_Addr_Type;

      Buffer :
        Ada.Streams.Stream_Element_Array
          (1 ..
             Ada.Streams.Stream_Element_Offset
               (Wire_Frame_Bytes));

      Last :
        Ada.Streams.Stream_Element_Offset;

      Offset :
        Ada.Streams.Stream_Element_Offset;

      Frame :
        Wire_Frame;

      Payload :
        CHVS_Payload;

      Peer_IP :
        Unbounded_String;

      This_Hash :
        Digest_512;

      Chain_OK :
        Boolean;

      Max_Replay_Entries :
        constant Positive := 64;

      type Replay_Entry is record
         Used :
           Boolean := False;

         Peer_IP :
           Unbounded_String := Null_Unbounded_String;

         Session :
           Session_Id := (others => 0);

         Last_Sequence :
           U64 := 0;

         Last_Hash :
           Digest_512 := (others => 0);
      end record;

      type Replay_Table is
        array (Positive range 1 .. Max_Replay_Entries)
          of Replay_Entry;

      Replay :
        Replay_Table;

      Next_Replacement :
        Positive := 1;

      Replay_Index :
        Natural := 0;

      function Locate_Replay
        (Peer    : Unbounded_String;
         Session : Session_Id) return Natural
      is
      begin
         for I in Replay'Range loop
            if Replay (I).Used
              and then Replay (I).Peer_IP = Peer
              and then Replay (I).Session = Session
            then
               return I;
            end if;
         end loop;

         return 0;
      end Locate_Replay;

      procedure Allocate_Replay
        (Peer    : Unbounded_String;
         Session : Session_Id;
         Index   : out Positive)
      is
      begin
         for I in Replay'Range loop
            if not Replay (I).Used then
               Replay (I).Used := True;
               Replay (I).Peer_IP := Peer;
               Replay (I).Session := Session;
               Replay (I).Last_Sequence := 0;
               Replay (I).Last_Hash := (others => 0);
               Index := I;
               return;
            end if;
         end loop;

         Index := Next_Replacement;

         Replay (Index).Used := True;
         Replay (Index).Peer_IP := Peer;
         Replay (Index).Session := Session;
         Replay (Index).Last_Sequence := 0;
         Replay (Index).Last_Hash := (others => 0);

         if Next_Replacement = Replay'Last then
            Next_Replacement := Replay'First;
         else
            Next_Replacement := Next_Replacement + 1;
         end if;
      end Allocate_Replay;

   begin
      if not Key_Valid then
         Ada.Text_IO.Put_Line
           ("CHVS receiver disabled: invalid key");
      else
         Net.Initialize;

      Net.Create_Socket
        (Server,
         Net.Family_Inet,
         Net.Socket_Stream);

      Net.Set_Socket_Option
        (Server,
         Net.Socket_Level,
         (Net.Reuse_Address, True));

      Server_Address.Addr :=
        Net.Inet_Addr (Bind_IP);

      Server_Address.Port :=
        Net.Port_Type (CHVS_TCP_Port);

      Net.Bind_Socket
        (Server,
         Server_Address);

      Net.Listen_Socket
        (Server);

      loop
         Net.Accept_Socket
           (Server,
            Client,
            Peer_Address);

         Peer_IP :=
           To_Unbounded_String
             (Net.Image (Peer_Address.Addr));

         if not Allowed_IP (To_String (Peer_IP)) then
            Inbound_Rejected :=
              Inbound_Rejected + 1;

            Net.Close_Socket (Client);

         else
            Offset := Buffer'First;

            while Offset <= Buffer'Last loop
               Net.Receive_Socket
                 (Client,
                  Buffer (Offset .. Buffer'Last),
                  Last);

               exit when Last < Offset;

               Offset := Last + 1;
            end loop;

            if Offset = Buffer'Last + 1 then
               Frame :=
                 From_Stream (Buffer);

               if Parse_Frame
                    (Frame,
                     CHVS_Key_Value,
                     Payload)
               then
                  Replay_Index :=
                    Locate_Replay
                      (Peer_IP,
                       Payload.Header.Session);

                  if Replay_Index = 0 then
                     declare
                        New_Index :
                          Positive;
                     begin
                        Allocate_Replay
                          (Peer_IP,
                           Payload.Header.Session,
                           New_Index);

                        Replay_Index := New_Index;
                     end;
                  end if;

                  Chain_OK := True;

                  if Replay (Replay_Index).Last_Sequence > 0 then
                     if Payload.Header.Sequence <=
                       Replay (Replay_Index).Last_Sequence
                     then
                        Chain_OK := False;

                     elsif Payload.Header.Sequence =
                       Replay (Replay_Index).Last_Sequence + 1
                     then
                        if Payload.Header.Previous_Frame_Hash /=
                          Replay (Replay_Index).Last_Hash
                        then
                           Chain_OK := False;
                        end if;

                     else
                        Inbound_Gaps :=
                          Inbound_Gaps + 1;
                     end if;
                  end if;

                  if Chain_OK then
                     Inbox.Put (Payload);

                     Inbound_Frames :=
                       Inbound_Frames + 1;

                     This_Hash :=
                       Frame_Hash (Frame);

                     Replay (Replay_Index).Last_Sequence :=
                       Payload.Header.Sequence;

                     Replay (Replay_Index).Last_Hash :=
                       This_Hash;

                  else
                     Inbound_Rejected :=
                       Inbound_Rejected + 1;
                  end if;

               else
                  Inbound_Rejected :=
                    Inbound_Rejected + 1;
               end if;
            else
               Inbound_Rejected :=
                 Inbound_Rejected + 1;
            end if;

            Net.Close_Socket (Client);
         end if;
      end loop;
      end if;

   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("CHVS receiver stopped: "
            & Ada.Exceptions.Exception_Message (E));
   end CHVS_Receiver;

   ---------------------------------------------------------------------------
   --  HTTP status server
   ---------------------------------------------------------------------------

   task HTTP_Server;

   task body HTTP_Server
   is
      Server :
        Net.Socket_Type;

      Client :
        Net.Socket_Type;

      Address :
        Net.Sock_Addr_Type;

      Peer :
        Net.Sock_Addr_Type;

      Request :
        Ada.Streams.Stream_Element_Array
          (1 .. 4_096);

      Last :
        Ada.Streams.Stream_Element_Offset;

      Request_Text :
        Unbounded_String;

      Response_Body :
        Unbounded_String;

      Header :
        Unbounded_String;

      Content_Type :
        Unbounded_String :=
          To_Unbounded_String ("text/html; charset=utf-8");

      procedure Send_Text
        (S : String)
      is
         Data :
           Ada.Streams.Stream_Element_Array
             (1 ..
                Ada.Streams.Stream_Element_Offset
                  (S'Length));
      begin
         for I in S'Range loop
            Data
              (Ada.Streams.Stream_Element_Offset
                 (I - S'First + 1)) :=
                   Ada.Streams.Stream_Element
                     (Character'Pos (S (I)));
         end loop;

         Send_All
           (Client,
            Data);
      end Send_Text;

   begin
      Net.Initialize;

      Net.Create_Socket
        (Server,
         Net.Family_Inet,
         Net.Socket_Stream);

      Net.Set_Socket_Option
        (Server,
         Net.Socket_Level,
         (Net.Reuse_Address, True));

      Address.Addr :=
        Net.Inet_Addr (Bind_IP);

      Address.Port :=
        Net.Port_Type (HTTP_TCP_Port);

      Net.Bind_Socket
        (Server,
         Address);

      Net.Listen_Socket
        (Server);

      loop
         Net.Accept_Socket
           (Server,
            Client,
            Peer);

         if Allowed_IP (Net.Image (Peer.Addr)) then
            Net.Receive_Socket
              (Client,
               Request,
               Last);

            Request_Text :=
              Null_Unbounded_String;

            if Last >= Request'First then
               for I in Request'First .. Last loop
                  Append
                    (Request_Text,
                     Character'Val (Request (I)));
               end loop;
            end if;

            if Ada.Strings.Fixed.Index
                 (To_String (Request_Text),
                  "GET /status.json ") > 0
            then
               Response_Body :=
                 To_Unbounded_String
                   (Read_Text
                      (State_Dir
                       & "/status.json"));

               Content_Type :=
                 To_Unbounded_String ("application/json");

            else
               Response_Body :=
                 To_Unbounded_String
                   (Read_Text
                      (Web_Root
                       & "/index.html"));

               Content_Type :=
                 To_Unbounded_String ("text/html; charset=utf-8");
            end if;

            Header :=
              To_Unbounded_String
                ("HTTP/1.1 200 OK"
                 & ASCII.CR & ASCII.LF
                 & "Content-Type: "
                 & To_String (Content_Type)
                 & ASCII.CR & ASCII.LF
                 & "Cache-Control: no-store"
                 & ASCII.CR & ASCII.LF
                 & "Content-Length:"
                 & Natural'Image
                     (Length (Response_Body))
                 & ASCII.CR & ASCII.LF
                 & "Connection: close"
                 & ASCII.CR & ASCII.LF
                 & ASCII.CR & ASCII.LF);

            Send_Text
              (To_String (Header)
               & To_String (Response_Body));
         end if;

         Net.Close_Socket (Client);
      end loop;

   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("HTTP server stopped: "
            & Ada.Exceptions.Exception_Message (E));
   end HTTP_Server;

   ---------------------------------------------------------------------------
   --  Source processing
   ---------------------------------------------------------------------------

   procedure Process_Byte
     (Ctx   : in out Source_Context;
      Value : Byte)
   is
      Digest :
        Digest_512;

      Credit :
        Credited_Bits;
   begin
      if Ctx.Used < Raw_Window_Bytes then
         Append_Byte
           (Ctx,
            Value);
      end if;

      if Window_Ready (Ctx) then
         Digest :=
           Condition_Source
             (Ctx.Id,
              Pool.Session,
              Pool.Generation + 1,
              Ctx.Window,
              Ctx.Used);

         Evaluate_Window (Ctx);

         Credit :=
           Ctx.Last_Credited_Bits;

         if Credit > 0
           and then Can_Contribute (Ctx)
         then
            Mix_Pool
              (Pool,
               Ctx.Id,
               Digest,
               Credit);

            if Pending_Credited_Bits >
              U64'Last - U64 (Credit)
            then
               Pending_Credited_Bits := U64'Last;
            else
               Pending_Credited_Bits :=
                 Pending_Credited_Bits + U64 (Credit);
            end if;
         end if;
      end if;
   end Process_Byte;

   procedure Feed_File
     (Path : String;
      Ctx  : in out Source_Context)
   is
      File :
        SIO.File_Type;

      Buffer :
        Ada.Streams.Stream_Element_Array
          (1 .. 4_096);

      Last :
        Ada.Streams.Stream_Element_Offset;
   begin
      if not Ada.Directories.Exists (Path) then
         return;
      end if;

      SIO.Open
        (File,
         SIO.In_File,
         Path);

      while not SIO.End_Of_File (File) loop
         SIO.Read
           (File,
            Buffer,
            Last);

         if Last >= Buffer'First then
            for I in Buffer'First .. Last loop
               Process_Byte
                 (Ctx,
                  Byte (Buffer (I)));
            end loop;
         end if;
      end loop;

      SIO.Close (File);

      Remove_If_Exists (Path);

   exception
      when others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;

         Remove_If_Exists (Path);
   end Feed_File;

   ---------------------------------------------------------------------------
   --  Chaosfield framed intake
   --
   --  Compatible ESP32 firmware emits newline-delimited JSON envelopes:
   --
   --    {"body":{...},"crc32":"xxxxxxxx"}\n
   --
   --  CRC32 covers the exact UTF-8 bytes of the nested body object.  Only
   --  CRC-valid Chaosfield protocol v1 conditioned SHA3-512 records are mixed.
   --  They influence the local pool with ZERO new local entropy credit.
   --
   --  The line buffer persists across collector reads because firmware status
   --  frames are much larger than one serial read.
   ---------------------------------------------------------------------------

   Chaosfield_Max_Line :
     constant Positive := 20_000;

   function Find_From
     (Source  : String;
      Pattern : String;
      From    : Positive) return Natural
   is
      First_Candidate :
        Natural;

      Last_Candidate :
        Natural;
   begin
      if Pattern'Length = 0
        or else Source'Length < Pattern'Length
      then
         return 0;
      end if;

      First_Candidate :=
        Natural'Max
          (Source'First,
           From);

      Last_Candidate :=
        Source'Last - Pattern'Length + 1;

      if First_Candidate > Last_Candidate then
         return 0;
      end if;

      for I in First_Candidate .. Last_Candidate loop
         if Source
              (I .. I + Pattern'Length - 1) = Pattern
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_From;

   function Find_Last
     (Source  : String;
      Pattern : String) return Natural
   is
      Last_Candidate :
        Natural;
   begin
      if Pattern'Length = 0
        or else Source'Length < Pattern'Length
      then
         return 0;
      end if;

      Last_Candidate :=
        Source'Last - Pattern'Length + 1;

      for I in reverse Source'First .. Last_Candidate loop
         if Source
              (I .. I + Pattern'Length - 1) = Pattern
         then
            return I;
         end if;
      end loop;

      return 0;
   end Find_Last;

   function Hex_Nibble
     (Ch : Character) return Integer
   is
   begin
      if Ch in '0' .. '9' then
         return
           Character'Pos (Ch)
           - Character'Pos ('0');

      elsif Ch in 'a' .. 'f' then
         return
           Character'Pos (Ch)
           - Character'Pos ('a')
           + 10;

      elsif Ch in 'A' .. 'F' then
         return
           Character'Pos (Ch)
           - Character'Pos ('A')
           + 10;

      else
         return -1;
      end if;
   end Hex_Nibble;

   function Is_Hex_String
     (Text : String) return Boolean
   is
   begin
      for Ch of Text loop
         if Hex_Nibble (Ch) < 0 then
            return False;
         end if;
      end loop;

      return True;
   end Is_Hex_String;

   function Decode_U32_Hex
     (Text  : String;
      Value : out U32) return Boolean
   is
      Result :
        U32 := 0;

      N :
        Integer;
   begin
      Value := 0;

      if Text'Length /= 8 then
         return False;
      end if;

      for Ch of Text loop
         N := Hex_Nibble (Ch);

         if N < 0 then
            return False;
         end if;

         Result :=
           Interfaces.Shift_Left (Result, 4)
           or U32 (N);
      end loop;

      Value := Result;
      return True;
   end Decode_U32_Hex;

   function Decode_Digest_Hex
     (Text   : String;
      Digest : out Digest_512) return Boolean
   is
      P :
        Natural;

      Hi :
        Integer;

      Lo :
        Integer;
   begin
      Digest := (others => 0);

      if Text'Length /= SHA3_512_Bytes * 2 then
         return False;
      end if;

      P := Text'First;

      for I in Digest'Range loop
         Hi := Hex_Nibble (Text (P));
         Lo := Hex_Nibble (Text (P + 1));

         if Hi < 0
           or else Lo < 0
         then
            Digest := (others => 0);
            return False;
         end if;

         Digest (I) :=
           Byte (Hi * 16 + Lo);

         P := P + 2;
      end loop;

      return True;
   end Decode_Digest_Hex;

   function String_Bytes
     (Text : String) return Byte_Array
   is
      Result :
        Byte_Array (1 .. Text'Length);

      P :
        Positive := 1;
   begin
      for Ch of Text loop
         Result (P) :=
           Byte (Character'Pos (Ch));

         P := P + 1;
      end loop;

      return Result;
   end String_Bytes;

   function Get_String_Field
     (Json_Body : String;
      Name      : String;
      Value : out Unbounded_String) return Boolean
   is
      Quote :
        constant Character := '"';

      Pattern :
        constant String :=
          Quote & Name & Quote & ":" & Quote;

      Start_Pos :
        Natural;

      Stop_Pos :
        Natural;
   begin
      Value := Null_Unbounded_String;

      Start_Pos :=
        Find_From
          (Json_Body,
           Pattern,
           Json_Body'First);

      if Start_Pos = 0 then
         return False;
      end if;

      Start_Pos :=
        Start_Pos + Pattern'Length;

      Stop_Pos :=
        Find_From
          (Json_Body,
           String'(1 => Quote),
           Positive (Start_Pos));

      if Stop_Pos = 0
        or else Stop_Pos < Start_Pos
      then
         return False;
      end if;

      if Stop_Pos = Start_Pos then
         Value := Null_Unbounded_String;
      else
         Value :=
           To_Unbounded_String
             (Json_Body
                (Start_Pos .. Stop_Pos - 1));
      end if;

      return True;
   end Get_String_Field;

   function Get_U64_Field
     (Json_Body : String;
      Name      : String;
      Value : out U64) return Boolean
   is
      Quote :
        constant Character := '"';

      Pattern :
        constant String :=
          Quote & Name & Quote & ":";

      Start_Pos :
        Natural;

      Stop_Pos :
        Natural;
   begin
      Value := 0;

      Start_Pos :=
        Find_From
          (Json_Body,
           Pattern,
           Json_Body'First);

      if Start_Pos = 0 then
         return False;
      end if;

      Start_Pos :=
        Start_Pos + Pattern'Length;

      Stop_Pos := Start_Pos;

      while Stop_Pos <= Json_Body'Last
        and then Json_Body (Stop_Pos) in '0' .. '9'
      loop
         Stop_Pos := Stop_Pos + 1;
      end loop;

      if Stop_Pos = Start_Pos then
         return False;
      end if;

      begin
         Value :=
           U64'Value
             (Json_Body
                (Start_Pos .. Stop_Pos - 1));

         return True;
      exception
         when others =>
            Value := 0;
            return False;
      end;
   end Get_U64_Field;

   procedure Reject_Chaosfield_Line
     (Bytes : Natural)
   is
   begin
      Chaosfield_Rejected_Bytes :=
        Chaosfield_Rejected_Bytes + U64 (Bytes);
   end Reject_Chaosfield_Line;

   procedure Process_Chaosfield_Line
     (Line : String)
   is
      Quote :
        constant Character := '"';

      Prefix :
        constant String :=
          "{" & Quote & "body" & Quote & ":";

      CRC_Marker :
        constant String :=
          "," & Quote & "crc32" & Quote & ":" & Quote;

      Clean_Last :
        Natural := Line'Last;

      CRC_Pos :
        Natural;

      CRC_Start :
        Natural;

      Body_Start :
        Natural;

      Claimed_CRC :
        U32;

      Actual_CRC :
        U32;

      Protocol :
        Unbounded_String;

      Kind :
        Unbounded_String;

      Session_Text :
        Unbounded_String;

      Algorithm :
        Unbounded_String;

      Qualification :
        Unbounded_String;

      Mix_Policy :
        Unbounded_String;

      Digest_Text :
        Unbounded_String;

      Sequence :
        U64;

      Credited :
        U64;

      Source_Count :
        U64;

      Contributor_Count :
        U64;

      Digest :
        Digest_512;
   begin
      if Line'Length = 0 then
         return;
      end if;

      if Line (Line'Last) = ASCII.CR then
         if Line'Length = 1 then
            return;
         end if;

         Clean_Last := Line'Last - 1;
      end if;

      declare
         Clean :
           constant String :=
             Line (Line'First .. Clean_Last);
      begin
         if Clean'Length < Prefix'Length + CRC_Marker'Length + 10
           or else
             Clean
               (Clean'First ..
                  Clean'First + Prefix'Length - 1) /= Prefix
         then
            Chaosfield_Nonprotocol_Lines :=
              Chaosfield_Nonprotocol_Lines + 1;

            Reject_Chaosfield_Line (Clean'Length);
            return;
         end if;

         CRC_Pos :=
           Find_Last
             (Clean,
              CRC_Marker);

         if CRC_Pos = 0 then
            Chaosfield_Malformed_Frames :=
              Chaosfield_Malformed_Frames + 1;

            Reject_Chaosfield_Line (Clean'Length);
            return;
         end if;

         Body_Start :=
           Clean'First + Prefix'Length;

         if CRC_Pos <= Body_Start then
            Chaosfield_Malformed_Frames :=
              Chaosfield_Malformed_Frames + 1;

            Reject_Chaosfield_Line (Clean'Length);
            return;
         end if;

         CRC_Start :=
           CRC_Pos + CRC_Marker'Length;

         if CRC_Start + 9 /= Clean'Last
           or else Clean (CRC_Start + 8) /= Quote
           or else Clean (CRC_Start + 9) /= '}'
         then
            Chaosfield_Malformed_Frames :=
              Chaosfield_Malformed_Frames + 1;

            Reject_Chaosfield_Line (Clean'Length);
            return;
         end if;

         if not Decode_U32_Hex
                  (Clean
                     (CRC_Start .. CRC_Start + 7),
                   Claimed_CRC)
         then
            Chaosfield_Malformed_Frames :=
              Chaosfield_Malformed_Frames + 1;

            Reject_Chaosfield_Line (Clean'Length);
            return;
         end if;

         declare
            Json_Body :
              constant String :=
                Clean
                  (Body_Start .. CRC_Pos - 1);
         begin
            if Json_Body'Length < 2
              or else Json_Body (Json_Body'First) /= '{'
              or else Json_Body (Json_Body'Last) /= '}'
            then
               Chaosfield_Malformed_Frames :=
                 Chaosfield_Malformed_Frames + 1;

               Reject_Chaosfield_Line (Clean'Length);
               return;
            end if;

            Actual_CRC :=
              CRC32
                (String_Bytes (Json_Body));

            if Actual_CRC /= Claimed_CRC then
               Chaosfield_CRC_Failures :=
                 Chaosfield_CRC_Failures + 1;

               Reject_Chaosfield_Line (Clean'Length);
               return;
            end if;

            if not Get_String_Field
                     (Json_Body,
                      "protocol",
                      Protocol)
              or else To_String (Protocol) /=
                "chaos-spark-chaosfield/1"
            then
               Chaosfield_Malformed_Frames :=
                 Chaosfield_Malformed_Frames + 1;

               Reject_Chaosfield_Line (Clean'Length);
               return;
            end if;

            if not Get_String_Field
                     (Json_Body,
                      "session",
                      Session_Text)
              or else Length (Session_Text) /= 32
              or else not Is_Hex_String
                 (To_String (Session_Text))
              or else not Get_U64_Field
                 (Json_Body,
                  "seq",
                  Sequence)
              or else not Get_String_Field
                 (Json_Body,
                  "type",
                  Kind)
              or else
                (To_String (Kind) /= "status"
                 and then To_String (Kind) /= "conditioned")
              or else not Get_String_Field
                 (Json_Body,
                  "qualification",
                  Qualification)
              or else To_String (Qualification) /= "unqualified"
              or else not Get_String_Field
                 (Json_Body,
                  "mix_policy",
                  Mix_Policy)
              or else To_String (Mix_Policy) /=
                "private-state-fresh-input"
              or else not Get_U64_Field
                 (Json_Body,
                  "credited_entropy_bits",
                  Credited)
              or else Credited /= 0
              or else not Get_U64_Field
                 (Json_Body,
                  "source_count",
                  Source_Count)
              or else Source_Count /= 6
            then
               Chaosfield_Malformed_Frames :=
                 Chaosfield_Malformed_Frames + 1;

               Reject_Chaosfield_Line (Clean'Length);
               return;
            end if;

            Chaosfield_Protocol_Frames :=
              Chaosfield_Protocol_Frames + 1;

            Chaosfield_Last_Protocol_Ms :=
              Now_Ms;

            if To_String (Session_Text) /=
              Chaosfield_Last_Session
            then
               Chaosfield_Last_Session :=
                 To_String (Session_Text);

               Chaosfield_Have_Sequence := False;
            end if;

            if To_String (Kind) = "status" then
               Chaosfield_Status_Frames :=
                 Chaosfield_Status_Frames + 1;

               return;
            end if;

            if not Get_String_Field
                     (Json_Body,
                      "algorithm",
                      Algorithm)
              or else To_String (Algorithm) /= "SHA3-512"
              or else not Get_U64_Field
                 (Json_Body,
                  "contributor_count",
                  Contributor_Count)
              or else Contributor_Count = 0
              or else Contributor_Count > Source_Count
              or else not Get_String_Field
                 (Json_Body,
                  "conditioned_hex",
                  Digest_Text)
              or else not Decode_Digest_Hex
                 (To_String (Digest_Text),
                  Digest)
            then
               Chaosfield_Malformed_Frames :=
                 Chaosfield_Malformed_Frames + 1;

               Reject_Chaosfield_Line (Clean'Length);
               return;
            end if;

            if Chaosfield_Have_Sequence then
               if Sequence <= Chaosfield_Last_Sequence then
                  Chaosfield_Replays :=
                    Chaosfield_Replays + 1;

                  Reject_Chaosfield_Line (Clean'Length);
                  return;

               elsif Chaosfield_Last_Sequence < U64'Last
                 and then Sequence /=
                   Chaosfield_Last_Sequence + 1
               then
                  Chaosfield_Sequence_Gaps :=
                    Chaosfield_Sequence_Gaps + 1;
               end if;
            end if;

            Mix_Pool
              (Pool,
               Chaosfield,
               Digest,
               0);

            Chaosfield_Conditioned_Frames :=
              Chaosfield_Conditioned_Frames + 1;

            Chaosfield_Conditioned_Bytes :=
              Chaosfield_Conditioned_Bytes
              + U64 (SHA3_512_Bytes);

            Chaosfield_Last_Sequence := Sequence;
            Chaosfield_Have_Sequence := True;
            Chaosfield_Last_Mix_Ms := Now_Ms;
         end;
      end;

   exception
      when E : others =>
         Chaosfield_Malformed_Frames :=
           Chaosfield_Malformed_Frames + 1;

         Reject_Chaosfield_Line (Line'Length);

         Ada.Text_IO.Put_Line
           ("CHAOSFIELD frame error: "
            & Ada.Exceptions.Exception_Name (E)
            & ": "
            & Ada.Exceptions.Exception_Message (E));
   end Process_Chaosfield_Line;

   procedure Feed_Chaosfield
     (Path : String)
   is
      File :
        SIO.File_Type;

      Buffer :
        Ada.Streams.Stream_Element_Array
          (1 .. 4_096);

      Last :
        Ada.Streams.Stream_Element_Offset;

      Ch :
        Character;
   begin
      if not Ada.Directories.Exists (Path) then
         return;
      end if;

      SIO.Open
        (File,
         SIO.In_File,
         Path);

      while not SIO.End_Of_File (File) loop
         SIO.Read
           (File,
            Buffer,
            Last);

         if Last >= Buffer'First then
            for I in Buffer'First .. Last loop
               Ch :=
                 Character'Val
                   (Buffer (I));

               if Ch = ASCII.LF then
                  if Chaosfield_Discarding_Line then
                     Chaosfield_Discarding_Line := False;
                     Chaosfield_Line_Buffer :=
                       Null_Unbounded_String;

                  else
                     Process_Chaosfield_Line
                       (To_String
                          (Chaosfield_Line_Buffer));

                     Chaosfield_Line_Buffer :=
                       Null_Unbounded_String;
                  end if;

               elsif Chaosfield_Discarding_Line then
                  Chaosfield_Rejected_Bytes :=
                    Chaosfield_Rejected_Bytes + 1;

               elsif Length (Chaosfield_Line_Buffer) >=
                 Chaosfield_Max_Line
               then
                  Chaosfield_Malformed_Frames :=
                    Chaosfield_Malformed_Frames + 1;

                  Chaosfield_Rejected_Bytes :=
                    Chaosfield_Rejected_Bytes
                    + U64
                        (Length
                           (Chaosfield_Line_Buffer))
                    + 1;

                  Chaosfield_Line_Buffer :=
                    Null_Unbounded_String;

                  Chaosfield_Discarding_Line := True;

               else
                  Append
                    (Chaosfield_Line_Buffer,
                     Ch);
               end if;
            end loop;
         end if;
      end loop;

      SIO.Close (File);
      Remove_If_Exists (Path);

   exception
      when E : others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;

         Ada.Text_IO.Put_Line
           ("CHAOSFIELD collector error: "
            & Ada.Exceptions.Exception_Name (E)
            & ": "
            & Ada.Exceptions.Exception_Message (E));

         Remove_If_Exists (Path);
   end Feed_Chaosfield;

   procedure Update_Chaosfield_Health
   is
      Now :
        constant U64 := Now_Ms;

      Age :
        U64;
   begin
      if Chaosfield_Last_Protocol_Ms = 0
        or else Now < Chaosfield_Last_Protocol_Ms
      then
         Sources (Chaosfield).Health := Absent;
         return;
      end if;

      Age :=
        Now - Chaosfield_Last_Protocol_Ms;

      if Age <= 10_000 then
         if Chaosfield_Last_Mix_Ms > 0
           and then Now >= Chaosfield_Last_Mix_Ms
           and then Now - Chaosfield_Last_Mix_Ms <= 10_000
         then
            Sources (Chaosfield).Health := Healthy;
         else
            Sources (Chaosfield).Health := Warmup;
         end if;

      elsif Age <= 60_000 then
         Sources (Chaosfield).Health := Suspect;

      else
         Sources (Chaosfield).Health := Absent;
      end if;
   end Update_Chaosfield_Health;

   ---------------------------------------------------------------------------
   --  Camera frame-delta collector
   ---------------------------------------------------------------------------

   procedure Feed_Camera
     (Path : String;
      Ctx  : in out Source_Context)
   is
      Frame_Bytes :
        constant Positive :=
          160 * 120;

      Frame_Count :
        constant Positive := 25;

      Total_Bytes :
        constant Positive :=
          Frame_Bytes * Frame_Count;

      Buffer :
        Ada.Streams.Stream_Element_Array
          (1 ..
             Ada.Streams.Stream_Element_Offset
               (Total_Bytes));

      File :
        SIO.File_Type;

      Last :
        Ada.Streams.Stream_Element_Offset;

      Offset :
        Ada.Streams.Stream_Element_Offset;

      Current_Index :
        Natural;

      Next_Index :
        Natural;

      A :
        Integer;

      B :
        Integer;

      D :
        Integer;
   begin
      if not Ada.Directories.Exists (Path) then
         return;
      end if;

      SIO.Open
        (File,
         SIO.In_File,
         Path);

      Offset := Buffer'First;

      while Offset <= Buffer'Last
        and then not SIO.End_Of_File (File)
      loop
         SIO.Read
           (File,
            Buffer (Offset .. Buffer'Last),
            Last);

         exit when Last < Offset;

         Offset := Last + 1;
      end loop;

      SIO.Close (File);

      if Offset = Buffer'Last + 1 then
         ---------------------------------------------------------------------
         --  Camera temporal-activity source.
         --
         --  Compare all 24 adjacent frame pairs across ~5 seconds.  Only
         --  changed pixels become observations.  Unchanged pixels are not
         --  injected as thousands of zero bytes, so a still/dark room simply
         --  produces no camera observations instead of a fake stuck stream.
         ---------------------------------------------------------------------

         for Frame_Index in 0 .. Frame_Count - 2 loop
            for Pixel_Index in 0 .. Frame_Bytes - 1 loop
               Current_Index :=
                 Frame_Index * Frame_Bytes
                 + Pixel_Index
                 + 1;

               Next_Index :=
                 (Frame_Index + 1) * Frame_Bytes
                 + Pixel_Index
                 + 1;

               A :=
                 Integer
                   (Buffer
                      (Ada.Streams.Stream_Element_Offset
                         (Current_Index)));

               B :=
                 Integer
                   (Buffer
                      (Ada.Streams.Stream_Element_Offset
                         (Next_Index)));

               D := B - A;

               if D < 0 then
                  D := -D;
               end if;

               if D /= 0 then
                  Process_Byte
                    (Ctx,
                     Byte (D));
               end if;
            end loop;
         end loop;
      end if;

      Remove_If_Exists (Path);

   exception
      when E : others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;

         Ada.Text_IO.Put_Line
           ("CAMERA collector error: "
            & Ada.Exceptions.Exception_Name (E)
            & ": "
            & Ada.Exceptions.Exception_Message (E));

         Remove_If_Exists (Path);
   end Feed_Camera;

   ---------------------------------------------------------------------------
   --  Microphone temporal-delta collector
   --
   --  The capture format is signed 16-bit little-endian PCM.  Feeding those
   --  raw bytes directly to byte-oriented APT/RCT tests confuses sample-format
   --  structure with sensor behavior.  Instead, derive the absolute delta
   --  between adjacent signed samples, fold the 16-bit delta into one byte,
   --  and feed only nonzero temporal observations.
   --
   --  This is a representation transform, not entropy creation.  Health tests
   --  and conservative crediting still operate on the resulting delta stream.
   ---------------------------------------------------------------------------

   procedure Feed_Microphone
     (Path : String;
      Ctx  : in out Source_Context)
   is
      Buffer :
        Ada.Streams.Stream_Element_Array
          (1 .. 65_536);

      File :
        SIO.File_Type;

      Last :
        Ada.Streams.Stream_Element_Offset;

      Offset :
        Ada.Streams.Stream_Element_Offset;

      Bytes_Read :
        Natural := 0;

      I :
        Natural := 1;

      Low_Byte :
        Integer;

      High_Byte :
        Integer;

      Sample :
        Integer;

      Previous_Sample :
        Integer := 0;

      Have_Previous :
        Boolean := False;

      Sample_Change :
        Integer;

      Folded :
        Byte;
   begin
      if not Ada.Directories.Exists (Path) then
         return;
      end if;

      SIO.Open
        (File,
         SIO.In_File,
         Path);

      Offset := Buffer'First;

      while Offset <= Buffer'Last
        and then not SIO.End_Of_File (File)
      loop
         SIO.Read
           (File,
            Buffer (Offset .. Buffer'Last),
            Last);

         exit when Last < Offset;

         Offset := Last + 1;
      end loop;

      SIO.Close (File);

      if Offset > Buffer'First then
         Bytes_Read :=
           Natural (Offset - Buffer'First);
      end if;

      while I + 1 <= Bytes_Read loop
         Low_Byte :=
           Integer
             (Buffer
                (Ada.Streams.Stream_Element_Offset (I)));

         High_Byte :=
           Integer
             (Buffer
                (Ada.Streams.Stream_Element_Offset (I + 1)));

         Sample :=
           Low_Byte + 256 * High_Byte;

         if Sample >= 32_768 then
            Sample := Sample - 65_536;
         end if;

         if Have_Previous then
            Sample_Change := Sample - Previous_Sample;

            if Sample_Change < 0 then
               Sample_Change := -Sample_Change;
            end if;

            if Sample_Change /= 0 then
               Folded :=
                 Byte (Sample_Change mod 256)
                 xor Byte ((Sample_Change / 256) mod 256);

               if Folded /= 0 then
                  Process_Byte
                    (Ctx,
                     Folded);
               end if;
            end if;
         end if;

         Previous_Sample := Sample;
         Have_Previous := True;
         I := I + 2;
      end loop;

      Remove_If_Exists (Path);

   exception
      when E : others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;

         Ada.Text_IO.Put_Line
           ("MICROPHONE collector error: "
            & Ada.Exceptions.Exception_Name (E)
            & ": "
            & Ada.Exceptions.Exception_Message (E));

         Remove_If_Exists (Path);
   end Feed_Microphone;

   ---------------------------------------------------------------------------
   --  Wi-Fi RSSI / movement
   ---------------------------------------------------------------------------

   procedure Collect_Wifi
   is
      Path :
        constant String :=
          Runtime_Dir & "/wifi.txt";

      Text :
        Unbounded_String :=
          Null_Unbounded_String;

      Value :
        Integer;

      RSSI_Delta :
        Integer;

      Ignore :
        Integer;
   begin
      Ignore :=
        Run
          ("iw dev "
           & Wifi_Interface
           & " link 2>/dev/null | "
           & "awk '/signal:/ {print $2; exit}' > "
           & Path);

      pragma Unreferenced (Ignore);

      Text :=
        To_Unbounded_String
          (Trim_ASCII_Whitespace
             (Read_Text (Path)));

      Remove_If_Exists (Path);

      if Length (Text) = 0 then
         return;
      end if;

      Value :=
        Integer'Value (To_String (Text));

      if Last_RSSI /= -127 then
         RSSI_Delta := Value - Last_RSSI;

         if RSSI_Delta < 0 then
            RSSI_Delta := -RSSI_Delta;
         end if;

         if RSSI_Delta > 255 then
            RSSI_Delta := 255;
         end if;

         Process_Byte
           (Sources (WiFi_RSSI),
            Byte (RSSI_Delta));

         Wifi_Motion_Score :=
           Natural'Min
             (1_000,
              Wifi_Motion_Score / 2
              + Natural (RSSI_Delta) * 100);
      end if;

      Process_Byte
        (Sources (WiFi_RSSI),
         Byte
           (Integer'Max
              (0,
               Integer'Min
                 (255,
                  Value + 128))));

      Last_RSSI := Value;

   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("WIFI collector error: "
            & Ada.Exceptions.Exception_Name (E)
            & ": "
            & Ada.Exceptions.Exception_Message (E));
   end Collect_Wifi;

   ---------------------------------------------------------------------------
   --  hwmon observation collector
   --
   --  These sysfs paths are examples from one Raspberry Pi 5 deployment.
   --  hwmon numbering can differ between systems and kernel configurations.
   ---------------------------------------------------------------------------

   procedure Collect_Hwmon
   is
      Paths :
        constant array (Positive range <>) of
          access constant String :=
            (new String'
               ("/sys/class/thermal/thermal_zone0/temp"),
             new String'
               ("/sys/class/hwmon/hwmon1/fan1_input"),
             new String'
               ("/sys/class/hwmon/hwmon3/in0_lcrit_alarm"));

      Text :
        Unbounded_String;

      Value :
        Long_Long_Integer;
   begin
      for P of Paths loop
         Text :=
           To_Unbounded_String
             (Trim_ASCII_Whitespace
                (Read_Text (P.all)));

         if Length (Text) > 0 then
            begin
               Value :=
                 Long_Long_Integer'Value
                   (To_String (Text));

               for Shift_Index in 0 .. 3 loop
                  Process_Byte
                    (Sources (Hwmon_Timing),
                     Byte
                       (Interfaces.Shift_Right
                          (Interfaces.Unsigned_64
                             (abs Value),
                           Shift_Index * 8)
                        and 16#FF#));
               end loop;
            exception
               when E : others =>
                  Ada.Text_IO.Put_Line
                    ("HWMON collector error ["
                     & P.all
                     & "]: "
                     & Ada.Exceptions.Exception_Name (E)
                     & ": "
                     & Ada.Exceptions.Exception_Message (E));
            end;
         end if;
      end loop;
   end Collect_Hwmon;

   ---------------------------------------------------------------------------
   --  Spool
   ---------------------------------------------------------------------------

   procedure Append_Spool
     (Frame : Wire_Frame)
   is
      File :
        SIO.File_Type;

      Data :
        Ada.Streams.Stream_Element_Array
          (1 ..
             Ada.Streams.Stream_Element_Offset
               (Wire_Frame_Bytes));
   begin
      Data := To_Stream (Frame);

      if Ada.Directories.Exists
           (State_Dir & "/spool.chvs")
      then
         SIO.Open
           (File,
            SIO.Append_File,
            State_Dir & "/spool.chvs");
      else
         SIO.Create
           (File,
            SIO.Out_File,
            State_Dir & "/spool.chvs");
      end if;

      SIO.Write
        (File,
         Data);

      SIO.Close (File);

   exception
      when others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;
   end Append_Spool;

   ---------------------------------------------------------------------------
   --  Outbound CHVS
   ---------------------------------------------------------------------------

   procedure Send_To_Peer
     (Token : String;
      Frame : Wire_Frame)
   is
      Clean :
        constant String :=
          Ada.Strings.Fixed.Trim
            (Token,
             Ada.Strings.Both);

      Colon :
        Natural := 0;

      Socket :
        Net.Socket_Type;

      Address :
        Net.Sock_Addr_Type;

      Data :
        Ada.Streams.Stream_Element_Array :=
          To_Stream (Frame);

      IP :
        Unbounded_String;

      Port :
        Positive := CHVS_TCP_Port;
   begin
      if Clean'Length = 0 then
         return;
      end if;

      for I in Clean'Range loop
         if Clean (I) = ':' then
            Colon := I;
            exit;
         end if;
      end loop;

      if Colon = 0 then
         IP :=
           To_Unbounded_String (Clean);
      elsif Colon = Clean'First
        or else Colon = Clean'Last
      then
         return;
      else
         IP :=
           To_Unbounded_String
             (Clean
                (Clean'First .. Colon - 1));

         Port :=
           Positive'Value
             (Clean
                (Colon + 1 .. Clean'Last));
      end if;

      if not Allowed_IP (To_String (IP)) then
         return;
      end if;

      Net.Create_Socket
        (Socket,
         Net.Family_Inet,
         Net.Socket_Stream);

      Address.Addr :=
        Net.Inet_Addr (To_String (IP));

      Address.Port :=
        Net.Port_Type (Port);

      Net.Connect_Socket
        (Socket,
         Address);

      Send_All
        (Socket,
         Data);

      Net.Close_Socket (Socket);

      Outbound_Frames :=
        Outbound_Frames + 1;

   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("CHVS send failed ["
            & Clean
            & "]: "
            & Ada.Exceptions.Exception_Message (E));

         begin
            Net.Close_Socket (Socket);
         exception
            when others =>
               null;
         end;
   end Send_To_Peer;

   procedure Send_To_Peers
     (Frame : Wire_Frame)
   is
      Start :
        Natural;

      Stop :
        Natural;

      I :
        Natural;
   begin
      if Peers'Length = 0 then
         return;
      end if;

      Start := Peers'First;
      I := Start;

      while I <= Peers'Last + 1 loop
         if I > Peers'Last
           or else Peers (I) = ','
         then
            Stop := I - 1;

            if Stop >= Start then
               Send_To_Peer
                 (Peers (Start .. Stop),
                  Frame);
            end if;

            Start := I + 1;
         end if;

         I := I + 1;
      end loop;
   end Send_To_Peers;

   ---------------------------------------------------------------------------
   --  JSON
   ---------------------------------------------------------------------------

   function Health_String
     (H : Health_State) return String
   is
   begin
      return
        Ada.Strings.Fixed.Trim
          (Health_State'Image (H),
           Ada.Strings.Both);
   end Health_String;

   function Class_String
     (K : Source_Class) return String
   is
   begin
      return
        Ada.Strings.Fixed.Trim
          (Source_Class'Image (K),
           Ada.Strings.Both);
   end Class_String;

   function Boolean_JSON
     (Value : Boolean) return String
   is
   begin
      if Value then
         return "true";
      else
         return "false";
      end if;
   end Boolean_JSON;

   procedure Write_Status
   is
      File :
        Ada.Text_IO.File_Type;

      Tmp :
        constant String :=
          State_Dir & "/status.json.tmp";

      Final :
        constant String :=
          State_Dir & "/status.json";

      First :
        Boolean := True;
   begin
      Ada.Text_IO.Create
        (File,
         Ada.Text_IO.Out_File,
         Tmp);

      Ada.Text_IO.Put_Line
        (File,
         "{");

      Ada.Text_IO.Put_Line
        (File,
         """name"":""chaos-spark"",");

      Ada.Text_IO.Put_Line
        (File,
         """bind_ip"":"""
         & Bind_IP
         & """,");

      Ada.Text_IO.Put_Line
        (File,
         """session"":"""
         & Hex (Session)
         & """,");

      Ada.Text_IO.Put_Line
        (File,
         """pool_generation"":"
         & U64'Image (Pool.Generation)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """chvs_sequence"":"
         & U64'Image (Pool.Sequence)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """inbound_frames"":"
         & U64'Image (Inbound_Frames)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """inbound_rejected"":"
         & U64'Image (Inbound_Rejected)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """inbound_gaps"":"
         & U64'Image (Inbound_Gaps)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """outbound_frames"":"
         & U64'Image (Outbound_Frames)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """pending_credited_bits"":"
         & U64'Image (Pending_Credited_Bits)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """chaosfield_protocol"":{");

      Ada.Text_IO.Put_Line
        (File,
         """protocol_frames"":"
         & U64'Image (Chaosfield_Protocol_Frames)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """status_frames"":"
         & U64'Image (Chaosfield_Status_Frames)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """conditioned_frames"":"
         & U64'Image (Chaosfield_Conditioned_Frames)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """conditioned_bytes"":"
         & U64'Image (Chaosfield_Conditioned_Bytes)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """crc_failures"":"
         & U64'Image (Chaosfield_CRC_Failures)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """malformed_frames"":"
         & U64'Image (Chaosfield_Malformed_Frames)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """nonprotocol_lines"":"
         & U64'Image (Chaosfield_Nonprotocol_Lines)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """sequence_gaps"":"
         & U64'Image (Chaosfield_Sequence_Gaps)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """replays"":"
         & U64'Image (Chaosfield_Replays)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """rejected_bytes"":"
         & U64'Image (Chaosfield_Rejected_Bytes)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """last_session"":"""
         & Chaosfield_Last_Session
         & """,");

      Ada.Text_IO.Put_Line
        (File,
         """last_sequence"":"
         & U64'Image (Chaosfield_Last_Sequence)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """have_sequence"":"
         & Boolean_JSON (Chaosfield_Have_Sequence)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """last_protocol_ms"":"
         & U64'Image (Chaosfield_Last_Protocol_Ms)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """last_mix_ms"":"
         & U64'Image (Chaosfield_Last_Mix_Ms));

      Ada.Text_IO.Put_Line
        (File,
         "},");

      Ada.Text_IO.Put_Line
        (File,
         """remote_provenance"":{");

      Ada.Text_IO.Put_Line
        (File,
         """frames_mixed"":"
         & U64'Image (Remote_Frames_Mixed)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """bytes_mixed"":"
         & U64'Image (Remote_Bytes_Mixed)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """last_session"":"""
         & Hex (Last_Remote_Session)
         & """,");

      Ada.Text_IO.Put_Line
        (File,
         """last_sequence"":"
         & U64'Image (Last_Remote_Sequence)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """last_source_bitmap"":"
         & U32'Image (Last_Remote_Source_Bitmap)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """last_healthy_bitmap"":"
         & U32'Image (Last_Remote_Healthy_Bitmap)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """last_origin_credit"":"
         & U32'Image (Last_Remote_Origin_Credit));

      Ada.Text_IO.Put_Line
        (File,
         "},");

      Ada.Text_IO.Put_Line
        (File,
         """wifi_motion_score"":"
         & Natural'Image (Wifi_Motion_Score)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """conditioned"":{");

      Ada.Text_IO.Put_Line
        (File,
         """sample_bytes"":"
         & Window_Byte_Count'Image
             (Conditioned_Metrics.Sample_Bytes)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """shannon_milli"":"
         & Entropy_Milli'Image
             (Conditioned_Metrics.Shannon_Milli)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """min_entropy_milli"":"
         & Entropy_Milli'Image
             (Conditioned_Metrics.MCV_Min_Milli)
         & ",");

      Ada.Text_IO.Put_Line
        (File,
         """markov_milli"":"
         & Entropy_Milli'Image
             (Conditioned_Metrics.Markov_Milli));

      Ada.Text_IO.Put_Line
        (File,
         "},");

      Ada.Text_IO.Put_Line
        (File,
         """sources"":[");

      for Id in Source_Id loop
         if not First then
            Ada.Text_IO.Put_Line
              (File,
               ",");
         end if;

         First := False;

         Ada.Text_IO.Put
           (File,
            "{""id"":"""
            & Ada.Strings.Fixed.Trim
                (Source_Id'Image (Id),
                 Ada.Strings.Both)
            & """,");

         Ada.Text_IO.Put
           (File,
            """class"":"""
            & Class_String (Sources (Id).Class)
            & """,");

         Ada.Text_IO.Put
           (File,
            """health"":"""
            & Health_String (Sources (Id).Health)
            & """,");

         Ada.Text_IO.Put
           (File,
            """used"":"
            & Window_Byte_Count'Image
                (Sources (Id).Used)
            & ",");

         Ada.Text_IO.Put
           (File,
            """raw_bytes"":"
            & U64'Image
                (Sources (Id).Total_Raw_Bytes)
            & ",");

         Ada.Text_IO.Put
           (File,
            """accepted_bytes"":"
            & U64'Image
                (Sources (Id).Total_Accepted_Bytes)
            & ",");

         Ada.Text_IO.Put
           (File,
            """gated_bytes"":"
            & U64'Image
                (Sources (Id).Total_Gated_Bytes)
            & ",");

         Ada.Text_IO.Put
           (File,
            """credited_bits"":"
            & Credited_Bits'Image
                (Sources (Id).Last_Credited_Bits)
            & ",");

         Ada.Text_IO.Put
           (File,
            """shannon_milli"":"
            & Entropy_Milli'Image
                (Sources (Id).Last_Metrics.Shannon_Milli)
            & ",");

         Ada.Text_IO.Put
           (File,
            """min_entropy_milli"":"
            & Entropy_Milli'Image
                (Sources (Id).Last_Metrics.MCV_Min_Milli)
            & ",");

         Ada.Text_IO.Put
           (File,
            """markov_milli"":"
            & Entropy_Milli'Image
                (Sources (Id).Last_Metrics.Markov_Milli)
            & ",");

         Ada.Text_IO.Put
           (File,
            """chi_square_milli"":"
            & U64'Image
                (Sources (Id).Last_Metrics.Chi_Square_Milli)
            & ",");

         Ada.Text_IO.Put
           (File,
            """serial_correlation_micro"":"
            & Correlation_Micro'Image
                (Sources (Id).Last_Metrics.Serial_Correlation_Micro)
            & ",");

         Ada.Text_IO.Put
           (File,
            """unique_symbols"":"
            & Unique_Symbol_Count'Image
                (Sources (Id).Last_Metrics.Unique_Symbols)
            & ",");

         Ada.Text_IO.Put
           (File,
            """rct_pass"":"
            & Boolean_JSON
                (Sources (Id).Last_Metrics.RCT_Pass)
            & ",");

         Ada.Text_IO.Put
           (File,
            """apt_pass"":"
            & Boolean_JSON
                (Sources (Id).Last_Metrics.APT_Pass));

         Ada.Text_IO.Put
           (File,
            "}");
      end loop;

      Ada.Text_IO.Put_Line
        (File,
         "]");

      Ada.Text_IO.Put_Line
        (File,
         "}");

      Ada.Text_IO.Close (File);

      if Ada.Directories.Exists (Final) then
         Ada.Directories.Delete_File (Final);
      end if;

      Ada.Directories.Rename
        (Tmp,
         Final);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Write_Status;

   ---------------------------------------------------------------------------
   --  Aggregate frame metadata
   ---------------------------------------------------------------------------

   function Current_Source_Bitmap return U32
   is
      Result :
        U32 := 0;
   begin
      for Id in Source_Id loop
         if Sources (Id).Total_Raw_Bytes > 0 then
            Result :=
              Result or Source_Bit (Id);
         end if;
      end loop;

      if Chaosfield_Conditioned_Frames > 0 then
         Result :=
           Result or Source_Bit (Chaosfield);
      end if;

      if Remote_Frames_Mixed > 0 then
         Result :=
           Result or Source_Bit (Remote_CHVS);
      end if;

      return Result;
   end Current_Source_Bitmap;

   function Current_Healthy_Bitmap return U32
   is
      Result :
        U32 := 0;
   begin
      for Id in Source_Id loop
         if Sources (Id).Health = Healthy then
            Result :=
              Result or Source_Bit (Id);
         end if;
      end loop;

      return Result;
   end Current_Healthy_Bitmap;

   function Clamp_U32
     (Value : U64) return U32
   is
   begin
      if Value > U64 (U32'Last) then
         return U32'Last;
      else
         return U32 (Value);
      end if;
   end Clamp_U32;

   function Total_Raw return U64
   is
      Result :
        U64 := 0;
   begin
      for Id in Source_Id loop
         Result :=
           Result
           + Sources (Id).Total_Raw_Bytes;
      end loop;

      return Result;
   end Total_Raw;

   function Total_Accepted return U64
   is
      Result :
        U64 := 0;
   begin
      for Id in Source_Id loop
         Result :=
           Result
           + Sources (Id).Total_Accepted_Bytes;
      end loop;

      return Result;
   end Total_Accepted;

   function Total_Gated return U64
   is
      Result :
        U64 := 0;
   begin
      for Id in Source_Id loop
         Result :=
           Result
           + Sources (Id).Total_Gated_Bytes;
      end loop;

      return Result;
   end Total_Gated;

   ---------------------------------------------------------------------------
   --  Main
   ---------------------------------------------------------------------------

   Ignore :
     Integer;

   Last_Camera :
     U64 := 0;

   Last_Microphone :
     U64 := 0;

   Last_Bluetooth :
     U64 := 0;

   Last_Hwmon :
     U64 := 0;

   Last_Status :
     U64 := 0;

   Last_Emission :
     U64 := 0;

   Last_Emitted_Generation :
     U64 := 0;

   Remote_Available :
     Boolean;

   Remote_Payload :
     CHVS_Payload;

   Frame :
     Wire_Frame;

   Payload :
     CHVS_Payload;

   Report_Metrics :
     Entropy_Metrics;

begin
   Ensure_Runtime;
   Initialize_Sources;

   if not Key_Valid then
      Ada.Text_IO.Put_Line
        ("WARNING: invalid CHVS key; networking will not authenticate");
   end if;

   Ignore :=
     Run
       ("stty -F "
        & Chaosfield_Device
        & " 115200 raw -echo -ixon -ixoff "
        & "2>/dev/null || true");

   pragma Unreferenced (Ignore);

   Ada.Text_IO.Put_Line
     ("chaos-spark starting");

   Ada.Text_IO.Put_Line
     ("bind="
      & Bind_IP);

   Last_Camera     := Now_Ms;
   Last_Microphone := Last_Camera;
   Last_Bluetooth  := Last_Camera;
   Last_Hwmon      := Last_Camera;
   Last_Status     := Last_Camera;
   Last_Emission   := Last_Camera;

   Write_Status;

   loop
      ------------------------------------------------------------------------
      --  HWRNG
      ------------------------------------------------------------------------

      Ignore :=
        Run
          ("timeout 1 dd if=/dev/hwrng of="
           & Runtime_Dir
           & "/hwrng.raw bs=512 count=1 status=none "
           & "2>/dev/null");

      Feed_File
        (Runtime_Dir & "/hwrng.raw",
         Sources (Pi_HWRNG));

      ------------------------------------------------------------------------
      --  Chaosfield
      ------------------------------------------------------------------------

      Ignore :=
        Run
          ("timeout 1 dd if="
           & Chaosfield_Device
           & " of="
           & Runtime_Dir
           & "/chaosfield.raw bs=4096 count=1 status=none "
           & "2>/dev/null");

      Feed_Chaosfield
        (Runtime_Dir & "/chaosfield.raw");

      Update_Chaosfield_Health;

      ------------------------------------------------------------------------
      --  Wi-Fi RF movement
      ------------------------------------------------------------------------

      Collect_Wifi;

      ------------------------------------------------------------------------
      --  Camera, every ~30 seconds
      ------------------------------------------------------------------------

      if Now_Ms - Last_Camera >= 30_000 then
         Last_Camera := Now_Ms;

         Ignore :=
           Run
             ("timeout -k 1 15 ffmpeg -nostdin "
              & "-hide_banner -loglevel error "
              & "-f v4l2 "
              & "-input_format mjpeg "
              & "-video_size 640x480 "
              & "-framerate 5 "
              & "-i "
              & Camera_Device
              & " -frames:v 25 "
              & "-vf scale=160:120,format=gray "
              & "-f rawvideo -y "
              & Runtime_Dir
              & "/camera.raw 2>/dev/null");

         Feed_Camera
           (Runtime_Dir & "/camera.raw",
            Sources (Camera));
      end if;

      ------------------------------------------------------------------------
      --  Microphone, every ~30 seconds
      ------------------------------------------------------------------------

      if Now_Ms - Last_Microphone >= 30_000 then
         Last_Microphone := Now_Ms;

         Ignore :=
           Run
             ("timeout 6 arecord -q -D "
              & Audio_Device
              & " -f S16_LE -c 1 -r 8000 "
              & "-d 3 -t raw "
              & Runtime_Dir
              & "/microphone.raw 2>/dev/null");

         Feed_Microphone
           (Runtime_Dir & "/microphone.raw",
            Sources (Microphone));
      end if;

      ------------------------------------------------------------------------
      --  Bluetooth ambient RSSI
      ------------------------------------------------------------------------

      if Now_Ms - Last_Bluetooth >= 60_000 then
         Last_Bluetooth := Now_Ms;

         Ignore :=
           Run
             ("btmgmt stop-find >/dev/null 2>&1 || true; "
              & "timeout 10 btmgmt find 2>/dev/null | "
              & "awk '/dev_found:/ && / rssi / {"
              & "for(i=1;i<=NF;i++) {"
              & "if($i==""rssi"") {"
              & "v=$(i+1)+128; "
              & "if(v<0)v=0; "
              & "if(v>255)v=255; "
              & "printf ""%c"",v; "
              & "break;"
              & "}}}' > "
              & Runtime_Dir
              & "/bluetooth.raw; "
              & "btmgmt stop-find >/dev/null 2>&1 || true");

         Feed_File
           (Runtime_Dir & "/bluetooth.raw",
            Sources (Bluetooth));
      end if;

      ------------------------------------------------------------------------
      --  hwmon / thermal observation
      ------------------------------------------------------------------------

      if Now_Ms - Last_Hwmon >= 1_000 then
         Last_Hwmon := Now_Ms;
         Collect_Hwmon;
      end if;

      ------------------------------------------------------------------------
      --  Remote authenticated CHVS contribution.
      --
      --  It influences the pool but receives ZERO new local entropy credit.
      ------------------------------------------------------------------------

      Inbox.Take
        (Remote_Available,
         Remote_Payload);

      if Remote_Available then
         Mix_Pool
           (Pool,
            Remote_CHVS,
            Remote_Payload.Data,
            0);

         Remote_Frames_Mixed :=
           Remote_Frames_Mixed + 1;

         Remote_Bytes_Mixed :=
           Remote_Bytes_Mixed + U64 (SHA3_512_Bytes);

         Last_Remote_Session :=
           Remote_Payload.Header.Session;

         Last_Remote_Sequence :=
           Remote_Payload.Header.Sequence;

         Last_Remote_Source_Bitmap :=
           Remote_Payload.Header.Source_Bitmap;

         Last_Remote_Healthy_Bitmap :=
           Remote_Payload.Header.Healthy_Bitmap;

         Last_Remote_Origin_Credit :=
           Remote_Payload.Header.Credited_Entropy_Bits;
      end if;

      ------------------------------------------------------------------------
      --  Emit whenever the pool changed, but no faster than every 5 seconds.
      ------------------------------------------------------------------------

      if Key_Valid
        and then Pool.Generation >
          Last_Emitted_Generation
        and then Now_Ms - Last_Emission >= 5_000
      then
         Last_Emission :=
           Now_Ms;

         Last_Emitted_Generation :=
           Pool.Generation;

         if Conditioned_Metrics.Sample_Bytes >=
           Minimum_Window_Bytes
         then
            Report_Metrics :=
              Conditioned_Metrics;
         else
            Report_Metrics :=
              Sources (Pi_HWRNG).Last_Metrics;
         end if;

         Make_Frame
           (Pool           => Pool,
            Metrics        => Report_Metrics,
            Source_Bitmap  => Current_Source_Bitmap,
            Healthy_Bitmap => Current_Healthy_Bitmap,
            Raw_Bytes      => Clamp_U32 (Total_Raw),
            Accepted_Bytes => Clamp_U32 (Total_Accepted),
            Gated_Bytes    => Clamp_U32 (Total_Gated),
            Credited_Bits  => Clamp_U32 (Pending_Credited_Bits),
            Timestamp_Ms   => Now_Ms,
            Key            => CHVS_Key_Value,
            Payload        => Payload,
            Frame          => Frame);

         Add_Conditioned
           (Payload.Data);

         Append_Spool
           (Frame);

         Send_To_Peers
           (Frame);

         Pending_Credited_Bits := 0;
      end if;

      ------------------------------------------------------------------------
      --  JSON status
      ------------------------------------------------------------------------

      if Now_Ms - Last_Status >= 2_000 then
         Last_Status := Now_Ms;
         Write_Status;
      end if;

      delay 0.25;
   end loop;

end Chaos_Spark;
