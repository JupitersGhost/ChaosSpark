package body Chaos_Types
  with SPARK_Mode => On
is
   use type U64;

   ---------------------------------------------------------------------------
   --  Source defaults
   ---------------------------------------------------------------------------

   function Default_Class
     (Id : Source_Id) return Source_Class
   is
   begin
      case Id is
         when Pi_HWRNG
            | Camera
            | Microphone =>
            return Primary_Entropy;

         when Chaosfield =>
            return Remote_Conditioned;

         when WiFi_RSSI
            | Bluetooth =>
            return Supplemental_Entropy;

         when Hwmon_Timing =>
            return Observation_Only;

         when Remote_CHVS =>
            return Remote_Conditioned;
      end case;
   end Default_Class;

   function Default_Target
     (Id : Source_Id) return Window_Target
   is
   begin
      case Id is
         when Pi_HWRNG
            | Camera
            | Microphone =>
            return Raw_Window_Bytes;

         when Chaosfield
            | WiFi_RSSI
            | Bluetooth
            | Hwmon_Timing
            | Remote_CHVS =>
            return Minimum_Window_Bytes;
      end case;
   end Default_Target;

   function Is_Entropy_Eligible
     (Class : Source_Class) return Boolean
   is
   begin
      return Class /= Observation_Only;
   end Is_Entropy_Eligible;

   function Source_Bit
     (Id : Source_Id) return U32
   is
   begin
      case Id is
         when Pi_HWRNG =>
            return 16#0000_0001#;

         when Chaosfield =>
            return 16#0000_0002#;

         when Camera =>
            return 16#0000_0004#;

         when Microphone =>
            return 16#0000_0008#;

         when WiFi_RSSI =>
            return 16#0000_0010#;

         when Bluetooth =>
            return 16#0000_0020#;

         when Hwmon_Timing =>
            return 16#0000_0040#;

         when Remote_CHVS =>
            return 16#0000_0080#;
      end case;
   end Source_Bit;

   ---------------------------------------------------------------------------
   --  Metrics
   ---------------------------------------------------------------------------

   function Zero_Metrics return Entropy_Metrics
   is
   begin
      return
        (Sample_Bytes             => 0,
         Shannon_Milli            => 0,
         MCV_Min_Milli            => 0,
         Markov_Milli             => 0,
         Chi_Square_Milli         => 0,
         Serial_Correlation_Micro => 0,
         Ones                     => 0,
         Runs                     => 0,
         Unique_Symbols           => 0,
         Nonzero_Deltas           => 0,
         RCT_Pass                 => False,
         APT_Pass                 => False);
   end Zero_Metrics;

   ---------------------------------------------------------------------------
   --  Source creation / buffering
   ---------------------------------------------------------------------------

   function Make_Source
     (Id : Source_Id) return Source_Context
   is
      Result : Source_Context;
   begin
      Result.Id           := Id;
      Result.Class        := Default_Class (Id);
      Result.Target_Bytes := Default_Target (Id);
      Result.Health       := Absent;

      Result.Window := (others => 0);
      Result.Used   := 0;

      Result.Consecutive_Good := 0;
      Result.Consecutive_Bad  := 0;

      Result.RCT_Failures := 0;
      Result.APT_Failures := 0;

      Result.Total_Raw_Bytes      := 0;
      Result.Total_Accepted_Bytes := 0;
      Result.Total_Gated_Bytes    := 0;

      Result.Last_Metrics :=
        Zero_Metrics;

      Result.Last_Credited_Bits := 0;

      return Result;
   end Make_Source;

   procedure Reset_Window
     (Ctx : in out Source_Context)
   is
   begin
      Ctx.Window := (others => 0);
      Ctx.Used   := 0;
   end Reset_Window;

   procedure Append_Byte
     (Ctx   : in out Source_Context;
      Value : Byte)
   is
   begin
      Ctx.Window (Ctx.Used + 1) := Value;
      Ctx.Used := Ctx.Used + 1;

      if Ctx.Total_Raw_Bytes < U64'Last then
         Ctx.Total_Raw_Bytes :=
           Ctx.Total_Raw_Bytes + 1;
      end if;
   end Append_Byte;

   function Window_Ready
     (Ctx : Source_Context) return Boolean
   is
   begin
      return Ctx.Used >= Ctx.Target_Bytes;
   end Window_Ready;

   ---------------------------------------------------------------------------
   --  Health-state hysteresis
   ---------------------------------------------------------------------------

   procedure Register_Good_Window
     (Ctx : in out Source_Context)
   is
   begin
      if Ctx.Consecutive_Good < Health_Counter'Last then
         Ctx.Consecutive_Good :=
           Ctx.Consecutive_Good + 1;
      end if;

      Ctx.Consecutive_Bad := 0;

      case Ctx.Health is

         when Absent =>
            Ctx.Health := Warmup;

         when Warmup =>
            if Ctx.Consecutive_Good >= Warmup_Good_Windows then
               Ctx.Health := Healthy;
            end if;

         when Healthy =>
            null;

         when Suspect =>
            Ctx.Health := Warmup;

         when Quarantined =>
            if Ctx.Consecutive_Good >= Recovery_Good_Windows then
               Ctx.Health := Warmup;
               Ctx.Consecutive_Good := 0;
            end if;

      end case;
   end Register_Good_Window;

   procedure Register_Bad_Window
     (Ctx : in out Source_Context)
   is
   begin
      Ctx.Consecutive_Good := 0;

      if Ctx.Consecutive_Bad < Health_Counter'Last then
         Ctx.Consecutive_Bad :=
           Ctx.Consecutive_Bad + 1;
      end if;

      case Ctx.Health is

         when Absent
            | Warmup
            | Healthy =>
            Ctx.Health := Suspect;

         when Suspect =>
            if Ctx.Consecutive_Bad >= Quarantine_Bad_Windows then
               Ctx.Health := Quarantined;
            end if;

         when Quarantined =>
            null;

      end case;
   end Register_Bad_Window;

   function Can_Contribute
     (Ctx : Source_Context) return Boolean
   is
   begin
      return
        Ctx.Health = Healthy
        and then Is_Entropy_Eligible (Ctx.Class);
   end Can_Contribute;

   ---------------------------------------------------------------------------
   --  Results / credit
   ---------------------------------------------------------------------------

   procedure Set_Metrics
     (Ctx     : in out Source_Context;
      Metrics : Entropy_Metrics)
   is
   begin
      Ctx.Last_Metrics := Metrics;
   end Set_Metrics;

   procedure Set_Credit
     (Ctx  : in out Source_Context;
      Bits : Credited_Bits)
   is
   begin
      Ctx.Last_Credited_Bits := Bits;
   end Set_Credit;

end Chaos_Types;
