with Interfaces;

package body Chaos_Stats
  with SPARK_Mode => Off
is
   use Chaos_Types;
   use type U64;
   use type Byte;

   subtype I64 is Interfaces.Integer_64;
   use type I64;

   type Symbol_Count_Array is
     array (Byte) of Natural;

   type Transition_Array is
     array (Byte, Byte) of Natural;

   ---------------------------------------------------------------------------
   --  Helpers
   ---------------------------------------------------------------------------

   function Min
     (A, B : Entropy_Milli) return Entropy_Milli
   is
   begin
      if A < B then
         return A;
      else
         return B;
      end if;
   end Min;

   procedure Saturating_Add
     (Value  : in out U64;
      Amount : U64)
   is
   begin
      if U64'Last - Value < Amount then
         Value := U64'Last;
      else
         Value := Value + Amount;
      end if;
   end Saturating_Add;

   ---------------------------------------------------------------------------
   --  Integer square root
   ---------------------------------------------------------------------------

   function Integer_Sqrt
     (N : U64) return U64
   is
      X : U64;
      Y : U64;
   begin
      if N = 0 then
         return 0;
      end if;

      X := N;
      Y := (X + 1) / 2;

      while Y < X loop
         X := Y;
         Y := (X + N / X) / 2;
      end loop;

      return X;
   end Integer_Sqrt;

   ---------------------------------------------------------------------------
   --  log2(Numerator / Denominator), returned as bits * 1000.
   --
   --  Uses Q16 fixed-point and repeated squaring for fractional log2.
   --  No floating point is required.
   ---------------------------------------------------------------------------

   function Log2_Ratio_Milli
     (Numerator   : Positive;
      Denominator : Positive) return Entropy_Milli
   is
      Scale : constant U64 := 65_536;
      Two   : constant U64 := 131_072;

      X : U64 :=
        (U64 (Numerator) * Scale) / U64 (Denominator);

      Whole : Natural := 0;
      Frac  : Natural := 0;

      type Weight_Array is
        array (Positive range <>) of Natural;

      Weights : constant Weight_Array :=
        (500, 250, 125, 62, 31, 16, 8, 4, 2, 1);

      Result : Natural;
   begin
      if Numerator <= Denominator then
         return 0;
      end if;

      while X >= Two loop
         X := X / 2;
         Whole := Whole + 1;
      end loop;

      for W of Weights loop
         X := (X * X) / Scale;

         if X >= Two then
            X := X / 2;
            Frac := Frac + W;
         end if;
      end loop;

      Result := Whole * 1_000 + Frac;

      if Result > Entropy_Milli'Last then
         return Entropy_Milli'Last;
      else
         return Entropy_Milli (Result);
      end if;
   end Log2_Ratio_Milli;

   ---------------------------------------------------------------------------
   --  Source-specific health-test thresholds.
   --
   --  These deliberately catch catastrophic/stuck-source behavior while
   --  allowing structured physical streams such as camera/audio deltas.
   ---------------------------------------------------------------------------

   function RCT_Cutoff
     (Id : Source_Id) return Positive
   is
   begin
      case Id is
         when Pi_HWRNG =>
            return 8;

         when Chaosfield =>
            return 16;

         when Camera
            | Microphone =>
            return 64;

         when WiFi_RSSI
            | Bluetooth =>
            return 128;

         when Hwmon_Timing
            | Remote_CHVS =>
            return 255;
      end case;
   end RCT_Cutoff;

   function APT_Cutoff
     (Id : Source_Id) return Positive
   is
   begin
      case Id is
         when Pi_HWRNG =>
            return 32;

         when Chaosfield =>
            return 64;

         when Camera
            | Microphone =>
            return 128;

         when WiFi_RSSI
            | Bluetooth =>
            return 384;

         when Hwmon_Timing
            | Remote_CHVS =>
            return APT_Window_Samples;
      end case;
   end APT_Cutoff;

   ---------------------------------------------------------------------------
   --  Repetition Count Test
   ---------------------------------------------------------------------------

   function RCT_Passes
     (Data   : Raw_Window;
      Used   : Window_Byte_Count;
      Cutoff : Positive) return Boolean
   is
      Run_Length : Natural := 1;
   begin
      if Used = 0 then
         return False;
      end if;

      if Used = 1 then
         return True;
      end if;

      for I in 2 .. Used loop
         if Data (I) = Data (I - 1) then
            Run_Length := Run_Length + 1;

            if Run_Length > Cutoff then
               return False;
            end if;
         else
            Run_Length := 1;
         end if;
      end loop;

      return True;
   end RCT_Passes;

   ---------------------------------------------------------------------------
   --  Adaptive Proportion Test
   --
   --  For every full 512-byte block, select the first symbol as the
   --  reference symbol and count its occurrences inside that block.
   ---------------------------------------------------------------------------

   function APT_Passes
     (Data   : Raw_Window;
      Used   : Window_Byte_Count;
      Cutoff : Positive) return Boolean
   is
      Start_Index : Natural := 1;
      Stop_Index  : Natural;
      Matches     : Natural;
      Reference   : Byte;
   begin
      if Used < APT_Window_Samples then
         return False;
      end if;

      while Start_Index + APT_Window_Samples - 1 <= Used loop
         Stop_Index :=
           Start_Index + APT_Window_Samples - 1;

         Reference := Data (Start_Index);
         Matches   := 0;

         for I in Start_Index .. Stop_Index loop
            if Data (I) = Reference then
               Matches := Matches + 1;
            end if;
         end loop;

         if Matches > Cutoff then
            return False;
         end if;

         Start_Index :=
           Start_Index + APT_Window_Samples;
      end loop;

      return True;
   end APT_Passes;

   ---------------------------------------------------------------------------
   --  Main analyzer
   ---------------------------------------------------------------------------

   function Analyze
     (Data : Raw_Window;
      Used : Window_Byte_Count;
      Id   : Source_Id) return Entropy_Metrics
   is
      Counts :
        Symbol_Count_Array := (others => 0);

      Transitions :
        Transition_Array := (others => (others => 0));

      Result :
        Entropy_Metrics := Zero_Metrics;

      Max_Count :
        Natural := 0;

      Shannon_Accumulator :
        U64 := 0;

      Chi_Accumulator :
        U64 := 0;

      Unique :
        Natural := 0;

      Delta_Count :
        Natural := 0;

      ------------------------------------------------------------------------
      --  Bit metrics
      ------------------------------------------------------------------------

      Previous_Bit :
        Boolean := False;

      Have_Previous_Bit :
        Boolean := False;

      Bit_Value :
        Natural;

      Value_N :
        Natural;

      Ones_Count :
        U64 := 0;

      Run_Count :
        U64 := 0;

      ------------------------------------------------------------------------
      --  Serial-correlation components
      ------------------------------------------------------------------------

      Corr_Numerator :
        I64 := 0;

      Corr_X2 :
        U64 := 0;

      Corr_Y2 :
        U64 := 0;

      X :
        I64;

      Y :
        I64;

      Corr_Denominator :
        U64;

      Corr_Scaled :
        I64;

      ------------------------------------------------------------------------
      --  Temporary calculations
      ------------------------------------------------------------------------

      Count_Value :
        Natural;

      Diff :
        I64;

      Abs_Diff :
        U64;

      Pair_Max :
        Natural;

      Predictor_Hits :
        Natural := 0;

   begin
      Result.Sample_Bytes := Used;

      if Used = 0 then
         return Result;
      end if;

      ------------------------------------------------------------------------
      --  Histograms, bit metrics and byte deltas
      ------------------------------------------------------------------------

      for I in 1 .. Used loop
         Counts (Data (I)) :=
           Counts (Data (I)) + 1;

         Value_N := Natural (Data (I));

         for Bit_Position in 0 .. 7 loop
            Bit_Value :=
              (Value_N / (2 ** Bit_Position)) mod 2;

            if Bit_Value = 1 then
               Ones_Count := Ones_Count + 1;
            end if;

            if not Have_Previous_Bit then
               Previous_Bit :=
                 (Bit_Value = 1);

               Have_Previous_Bit := True;
               Run_Count := 1;
            elsif Previous_Bit /= (Bit_Value = 1) then
               Run_Count := Run_Count + 1;
               Previous_Bit := (Bit_Value = 1);
            end if;
         end loop;

         if I > 1 then
            if Data (I) /= Data (I - 1) then
               Delta_Count := Delta_Count + 1;
            end if;

            Transitions
              (Data (I - 1), Data (I)) :=
              Transitions
                (Data (I - 1), Data (I)) + 1;

            X :=
              I64 (Integer (Data (I - 1)) * 2 - 255);

            Y :=
              I64 (Integer (Data (I)) * 2 - 255);

            Corr_Numerator :=
              Corr_Numerator + X * Y;

            Corr_X2 :=
              Corr_X2 + U64 (X * X);

            Corr_Y2 :=
              Corr_Y2 + U64 (Y * Y);
         end if;
      end loop;

      Result.Ones := Ones_Count;
      Result.Runs := Run_Count;

      Result.Nonzero_Deltas :=
        Window_Byte_Count (Delta_Count);

      ------------------------------------------------------------------------
      --  Symbol statistics
      ------------------------------------------------------------------------

      for Symbol in Byte loop
         Count_Value := Counts (Symbol);

         if Count_Value > 0 then
            Unique := Unique + 1;

            if Count_Value > Max_Count then
               Max_Count := Count_Value;
            end if;

            Shannon_Accumulator :=
              Shannon_Accumulator
              + U64 (Count_Value)
                * U64
                    (Log2_Ratio_Milli
                       (Positive (Used),
                        Positive (Count_Value)));
         end if;

         ---------------------------------------------------------------------
         --  Chi-square:
         --
         --      Σ ((count - expected)^2 / expected)
         --
         --  with expected = Used / 256, algebraically:
         --
         --      Σ ((256*count - Used)^2 / Used)
         ---------------------------------------------------------------------

         Diff :=
           I64 (Count_Value * 256)
           - I64 (Used);

         if Diff < 0 then
            Abs_Diff := U64 (-Diff);
         else
            Abs_Diff := U64 (Diff);
         end if;

         Chi_Accumulator :=
           Chi_Accumulator
           + Abs_Diff * Abs_Diff;
      end loop;

      Result.Unique_Symbols :=
        Unique_Symbol_Count (Unique);

      Result.Shannon_Milli :=
        Entropy_Milli
          (Natural
             (Shannon_Accumulator / U64 (Used)));

      if Max_Count > 0 then
         Result.MCV_Min_Milli :=
           Log2_Ratio_Milli
             (Positive (Used),
              Positive (Max_Count));
      end if;

      Result.Chi_Square_Milli :=
        (Chi_Accumulator * 1_000)
        / U64 (Used);

      ------------------------------------------------------------------------
      --  First-order predictor / Markov-style estimate
      --
      --  For each previous byte value, choose the most frequently observed
      --  successor and sum those predictor hits globally.  This avoids a
      --  sparse, rarely-seen state collapsing the entire estimate to zero.
      --
      --  This is an engineering first-order predictor metric.  It is NOT the
      --  NIST SP 800-90B Markov estimator and must not be described as one.
      ------------------------------------------------------------------------

      for Previous in Byte loop
         Pair_Max := 0;

         for Current in Byte loop
            if Transitions (Previous, Current) > Pair_Max then
               Pair_Max :=
                 Transitions (Previous, Current);
            end if;
         end loop;

         Predictor_Hits :=
           Predictor_Hits + Pair_Max;
      end loop;

      if Used > 1
        and then Predictor_Hits > 0
      then
         Result.Markov_Milli :=
           Log2_Ratio_Milli
             (Positive (Used - 1),
              Positive (Predictor_Hits));
      else
         Result.Markov_Milli := 0;
      end if;

      ------------------------------------------------------------------------
      --  Serial correlation
      ------------------------------------------------------------------------

      if Used > 1
        and then Corr_X2 > 0
        and then Corr_Y2 > 0
      then
         Corr_Denominator :=
           Integer_Sqrt
             (Corr_X2 * Corr_Y2);

         if Corr_Denominator > 0 then
            Corr_Scaled :=
              (Corr_Numerator * 1_000_000)
              / I64 (Corr_Denominator);

            if Corr_Scaled <
              I64 (Correlation_Micro'First)
            then
               Result.Serial_Correlation_Micro :=
                 Correlation_Micro'First;

            elsif Corr_Scaled >
              I64 (Correlation_Micro'Last)
            then
               Result.Serial_Correlation_Micro :=
                 Correlation_Micro'Last;

            else
               Result.Serial_Correlation_Micro :=
                 Correlation_Micro (Corr_Scaled);
            end if;
         end if;
      end if;

      ------------------------------------------------------------------------
      --  Continuous health tests
      ------------------------------------------------------------------------

      Result.RCT_Pass :=
        RCT_Passes
          (Data,
           Used,
           RCT_Cutoff (Id));

      Result.APT_Pass :=
        APT_Passes
          (Data,
           Used,
           APT_Cutoff (Id));

      return Result;
   end Analyze;

   ---------------------------------------------------------------------------
   --  Conservative estimator
   ---------------------------------------------------------------------------

   function Conservative_Min_Milli
     (Metrics : Entropy_Metrics) return Entropy_Milli
   is
      Result : Entropy_Milli;
   begin
      Result :=
        Min
          (Metrics.Shannon_Milli,
           Metrics.MCV_Min_Milli);

      Result :=
        Min
          (Result,
           Metrics.Markov_Milli);

      return Result;
   end Conservative_Min_Milli;

   ---------------------------------------------------------------------------
   --  Conservative entropy-credit calculation
   ---------------------------------------------------------------------------

   function Calculate_Credit
     (Metrics : Entropy_Metrics;
      Class   : Source_Class) return Credited_Bits
   is
      Base_Milli :
        Entropy_Milli;

      Weight_Percent :
        Natural := 0;

      Raw_Bits_Milli :
        U64;

      Weighted_Bits :
        U64;

      Maximum :
        constant U64 :=
          U64 (Credited_Bits'Last);
   begin
      if Metrics.Sample_Bytes < Minimum_Window_Bytes then
         return 0;
      end if;

      if not Metrics.RCT_Pass
        or else not Metrics.APT_Pass
      then
         return 0;
      end if;

      if Metrics.Unique_Symbols < 2 then
         return 0;
      end if;

      Base_Milli :=
        Conservative_Min_Milli (Metrics);

      case Class is
         when Primary_Entropy =>
            Weight_Percent := 75;

         when Supplemental_Entropy =>
            Weight_Percent := 25;

         when Observation_Only
            | Remote_Conditioned =>
            return 0;
      end case;

      ------------------------------------------------------------------------
      --  Base_Milli is bits/byte * 1000.
      --
      --  Divide by 1000 to convert to estimated bits, then apply the
      --  conservative source-class safety factor.
      ------------------------------------------------------------------------

      Raw_Bits_Milli :=
        U64 (Base_Milli)
        * U64 (Metrics.Sample_Bytes);

      Weighted_Bits :=
        ((Raw_Bits_Milli * U64 (Weight_Percent)) / 100)
        / 1_000;

      if Weighted_Bits > Maximum then
         return Credited_Bits'Last;
      else
         return Credited_Bits (Weighted_Bits);
      end if;
   end Calculate_Credit;

   ---------------------------------------------------------------------------
   --  Complete window evaluation / health gating
   ---------------------------------------------------------------------------

   procedure Evaluate_Window
     (Ctx : in out Source_Context)
   is
      Metrics :
        Entropy_Metrics;

      Credit :
        Credited_Bits := 0;

      Window_Is_Good :
        Boolean;
   begin
      Metrics :=
        Analyze
          (Ctx.Window,
           Ctx.Used,
           Ctx.Id);

      Set_Metrics
        (Ctx,
         Metrics);

      Window_Is_Good :=
        Ctx.Used >= Minimum_Window_Bytes
        and then Metrics.RCT_Pass
        and then Metrics.APT_Pass
        and then Metrics.Unique_Symbols >= 2;

      if Window_Is_Good then
         Register_Good_Window (Ctx);

         Saturating_Add
           (Ctx.Total_Accepted_Bytes,
            U64 (Ctx.Used));

      else
         if not Metrics.RCT_Pass then
            Saturating_Add
              (Ctx.RCT_Failures, 1);
         end if;

         if not Metrics.APT_Pass then
            Saturating_Add
              (Ctx.APT_Failures, 1);
         end if;

         Register_Bad_Window (Ctx);

         Saturating_Add
           (Ctx.Total_Gated_Bytes,
            U64 (Ctx.Used));
      end if;

      ------------------------------------------------------------------------
      --  Even a statistically-good warmup window receives zero credit until
      --  the source state machine has promoted it to Healthy.
      ------------------------------------------------------------------------

      if Can_Contribute (Ctx) then
         Credit :=
           Calculate_Credit
             (Metrics,
              Ctx.Class);
      else
         Credit := 0;
      end if;

      Set_Credit
        (Ctx,
         Credit);

      Reset_Window (Ctx);
   end Evaluate_Window;

end Chaos_Stats;
