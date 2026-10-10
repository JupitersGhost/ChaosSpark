with Interfaces;

package Chaos_Types
  with SPARK_Mode => On
is
   ---------------------------------------------------------------------------
   --  Fundamental integer types
   ---------------------------------------------------------------------------

   subtype Byte is Interfaces.Unsigned_8;
   subtype U16  is Interfaces.Unsigned_16;
   subtype U32  is Interfaces.Unsigned_32;
   subtype U64  is Interfaces.Unsigned_64;

   type Byte_Array is array (Positive range <>) of Byte;

   ---------------------------------------------------------------------------
   --  Canonical entropy-window sizing
   --
   --  8 KiB is the absolute minimum permitted scoring window.
   --  16 KiB is the normal/default window.
   ---------------------------------------------------------------------------

   Minimum_Window_Bytes : constant Positive := 8 * 1_024;
   Raw_Window_Bytes     : constant Positive := 16 * 1_024;

   SHA3_512_Bytes       : constant Positive := 64;
   Session_Id_Bytes     : constant Positive := 16;

   APT_Window_Samples   : constant Positive := 512;

   subtype Raw_Window is
     Byte_Array (1 .. Raw_Window_Bytes);

   subtype Digest_512 is
     Byte_Array (1 .. SHA3_512_Bytes);

   subtype Session_Id is
     Byte_Array (1 .. Session_Id_Bytes);

   ---------------------------------------------------------------------------
   --  Fixed point statistics
   --
   --  Entropy values are bits/byte * 1000.
   --
   --       7.921 bits/byte -> 7921
   --
   --  Avoid floating point in the trusted SPARK core.
   ---------------------------------------------------------------------------

   subtype Entropy_Milli is Natural range 0 .. 8_000;

   subtype Correlation_Micro is
     Integer range -1_000_000 .. 1_000_000;

   subtype Unique_Symbol_Count is
     Natural range 0 .. 256;

   subtype Window_Byte_Count is
     Natural range 0 .. Raw_Window_Bytes;

   subtype Window_Target is
     Positive range Minimum_Window_Bytes .. Raw_Window_Bytes;

   subtype Health_Counter is
     Natural range 0 .. 255;

   subtype Credited_Bits is
     Natural range 0 .. Raw_Window_Bytes * 8;

   ---------------------------------------------------------------------------
   --  Source classification
   ---------------------------------------------------------------------------

   type Source_Id is
     (Pi_HWRNG,
      Chaosfield,
      Camera,
      Microphone,
      WiFi_RSSI,
      Bluetooth,
      Hwmon_Timing,
      Remote_CHVS);

   type Source_Class is
     (Primary_Entropy,
      Supplemental_Entropy,
      Observation_Only,
      Remote_Conditioned);

   type Health_State is
     (Absent,
      Warmup,
      Healthy,
      Suspect,
      Quarantined);

   function Default_Class
     (Id : Source_Id) return Source_Class;

   function Default_Target
     (Id : Source_Id) return Window_Target;

   function Is_Entropy_Eligible
     (Class : Source_Class) return Boolean;

   function Source_Bit
     (Id : Source_Id) return U32;

   ---------------------------------------------------------------------------
   --  Statistical record
   ---------------------------------------------------------------------------

   type Entropy_Metrics is record
      Sample_Bytes : Window_Byte_Count := 0;

      Shannon_Milli : Entropy_Milli := 0;
      MCV_Min_Milli : Entropy_Milli := 0;
      Markov_Milli  : Entropy_Milli := 0;

      Chi_Square_Milli : U64 := 0;

      Serial_Correlation_Micro :
        Correlation_Micro := 0;

      Ones : U64 := 0;
      Runs : U64 := 0;

      Unique_Symbols :
        Unique_Symbol_Count := 0;

      Nonzero_Deltas :
        Window_Byte_Count := 0;

      RCT_Pass : Boolean := False;
      APT_Pass : Boolean := False;
   end record;

   function Zero_Metrics return Entropy_Metrics;

   ---------------------------------------------------------------------------
   --  Per-source acquisition window
   ---------------------------------------------------------------------------

   type Source_Context is record
      Id    : Source_Id    := Pi_HWRNG;
      Class : Source_Class := Primary_Entropy;

      Health : Health_State := Absent;

      Target_Bytes :
        Window_Target := Raw_Window_Bytes;

      Window :
        Raw_Window := (others => 0);

      Used :
        Window_Byte_Count := 0;

      Consecutive_Good :
        Health_Counter := 0;

      Consecutive_Bad :
        Health_Counter := 0;

      RCT_Failures : U64 := 0;
      APT_Failures : U64 := 0;

      Total_Raw_Bytes      : U64 := 0;
      Total_Accepted_Bytes : U64 := 0;
      Total_Gated_Bytes    : U64 := 0;

      Last_Metrics :
        Entropy_Metrics :=
          (others => <>);

      Last_Credited_Bits :
        Credited_Bits := 0;
   end record;

   type Source_Context_Array is
     array (Source_Id) of Source_Context;

   function Make_Source
     (Id : Source_Id) return Source_Context
   with
     Post =>
       Make_Source'Result.Id = Id
       and then
       Make_Source'Result.Class = Default_Class (Id)
       and then
       Make_Source'Result.Target_Bytes = Default_Target (Id)
       and then
       Make_Source'Result.Used = 0
       and then
       Make_Source'Result.Health = Absent;

   procedure Reset_Window
     (Ctx : in out Source_Context)
   with
     Post => Ctx.Used = 0;

   procedure Append_Byte
     (Ctx   : in out Source_Context;
      Value : Byte)
   with
     Pre  => Ctx.Used < Raw_Window_Bytes,
     Post => Ctx.Used = Ctx.Used'Old + 1;

   function Window_Ready
     (Ctx : Source_Context) return Boolean
   with
     Post =>
       Window_Ready'Result =
         (Ctx.Used >= Ctx.Target_Bytes);

   ---------------------------------------------------------------------------
   --  Health-state hysteresis
   ---------------------------------------------------------------------------

   Warmup_Good_Windows    : constant Health_Counter := 3;
   Recovery_Good_Windows  : constant Health_Counter := 5;
   Quarantine_Bad_Windows : constant Health_Counter := 3;

   procedure Register_Good_Window
     (Ctx : in out Source_Context)
   with
     Post => Ctx.Consecutive_Bad = 0;

   procedure Register_Bad_Window
     (Ctx : in out Source_Context)
   with
     Post => Ctx.Consecutive_Good = 0;

   function Can_Contribute
     (Ctx : Source_Context) return Boolean
   with
     Post =>
       Can_Contribute'Result =
         (Ctx.Health = Healthy
          and then Is_Entropy_Eligible (Ctx.Class));

   procedure Set_Metrics
     (Ctx     : in out Source_Context;
      Metrics : Entropy_Metrics)
   with
     Post => Ctx.Last_Metrics = Metrics;

   procedure Set_Credit
     (Ctx  : in out Source_Context;
      Bits : Credited_Bits)
   with
     Post => Ctx.Last_Credited_Bits = Bits;

   ---------------------------------------------------------------------------
   --  CHVS
   ---------------------------------------------------------------------------

   CHVS_Magic   : constant String := "CHVS";
   CHVS_Version : constant Byte   := 1;

   type CHVS_Header is record
      Version : Byte := CHVS_Version;
      Flags   : U16  := 0;

      Session :
        Session_Id := (others => 0);

      Sequence :
        U64 := 0;

      Timestamp_Ms :
        U64 := 0;

      Source_Bitmap :
        U32 := 0;

      Healthy_Bitmap :
        U32 := 0;

      Raw_Bytes :
        U32 := 0;

      Accepted_Bytes :
        U32 := 0;

      Gated_Bytes :
        U32 := 0;

      Window_Bytes :
        U16 := U16 (Raw_Window_Bytes);

      Shannon_Milli :
        U16 := 0;

      Min_Entropy_Milli :
        U16 := 0;

      Markov_Milli :
        U16 := 0;

      Credited_Entropy_Bits :
        U32 := 0;

      Payload_Length :
        U16 := U16 (SHA3_512_Bytes);

      Previous_Frame_Hash :
        Digest_512 := (others => 0);

      Payload_Hash :
        Digest_512 := (others => 0);
   end record;

   type CHVS_Payload is record
      Header : CHVS_Header;
      Data   : Digest_512 := (others => 0);
   end record;

end Chaos_Types;
