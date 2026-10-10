with Chaos_Types;

package Chaos_Stats
  with SPARK_Mode => Off
is
   use Chaos_Types;

   ---------------------------------------------------------------------------
   --  NIST SP 800-90B-style continuous health tests.
   --
   --  These are engineering health tests inspired by RCT/APT.  Thresholds
   --  are source-specific and are NOT a claim of NIST certification.
   ---------------------------------------------------------------------------

   function RCT_Cutoff
     (Id : Source_Id) return Positive;

   function APT_Cutoff
     (Id : Source_Id) return Positive;

   function RCT_Passes
     (Data   : Raw_Window;
      Used   : Window_Byte_Count;
      Cutoff : Positive) return Boolean;

   function APT_Passes
     (Data   : Raw_Window;
      Used   : Window_Byte_Count;
      Cutoff : Positive) return Boolean;

   ---------------------------------------------------------------------------
   --  Full statistical analysis
   ---------------------------------------------------------------------------

   function Analyze
     (Data : Raw_Window;
      Used : Window_Byte_Count;
      Id   : Source_Id) return Entropy_Metrics;

   ---------------------------------------------------------------------------
   --  Conservative entropy estimate.
   --
   --  Uses the minimum of:
   --    Shannon
   --    MCV min-entropy
   --    first-order predictor / Markov-style estimate
   ---------------------------------------------------------------------------

   function Conservative_Min_Milli
     (Metrics : Entropy_Metrics) return Entropy_Milli;

   ---------------------------------------------------------------------------
   --  Conservative credit accounting.
   --
   --  Primary physical sources:
   --       75% of conservative estimate.
   --
   --  Supplemental sources:
   --       25%.
   --
   --  Observation-only and received CHVS material:
   --       zero new local entropy credit.
   --
   --  A received CHVS frame carries its sender's independently-accounted
   --  credit.  We never infer fresh entropy merely from receiving a digest.
   ---------------------------------------------------------------------------

   function Calculate_Credit
     (Metrics : Entropy_Metrics;
      Class   : Source_Class) return Credited_Bits;

   ---------------------------------------------------------------------------
   --  Complete source-window evaluation.
   --
   --  Performs:
   --    RCT / APT
   --    Shannon
   --    MCV min-H
   --    first-order predictor / Markov-style estimate
   --    chi-square
   --    serial correlation
   --    monobit count
   --    bit-run count
   --    unique-symbol count
   --    nonzero byte-delta count
   --
   --  Updates source health/gating and resets the acquisition window.
   ---------------------------------------------------------------------------

   procedure Evaluate_Window
     (Ctx : in out Source_Context);

end Chaos_Stats;
