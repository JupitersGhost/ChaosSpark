with Chaos_Types;

package Chaos_CHVS
  with SPARK_Mode => Off
is
   use Chaos_Types;

   CHVS_TCP_Port  : constant Positive := 8_788;
   HTTP_TCP_Port  : constant Positive := 8_787;

   CHVS_Key_Bytes : constant Positive := 32;

   subtype CHVS_Key is
     Byte_Array (1 .. CHVS_Key_Bytes);

   Wire_Frame_Bytes : constant Positive := 333;

   subtype Wire_Frame is
     Byte_Array (1 .. Wire_Frame_Bytes);

   type Pool_State is record
      Session :
        Session_Id := (others => 0);

      Digest :
        Digest_512 := (others => 0);

      Previous_Frame_Hash :
        Digest_512 := (others => 0);

      Generation :
        U64 := 0;

      Sequence :
        U64 := 0;
   end record;

   function Decode_Key
     (Hex : String;
      Key : out CHVS_Key) return Boolean;

   function SHA3_512
     (Data : Byte_Array) return Digest_512;

   function HMAC_SHA3_512
     (Key  : CHVS_Key;
      Data : Byte_Array) return Digest_512;

   function CRC32
     (Data : Byte_Array) return U32;

   function Initialize_Pool
     (Session : Session_Id) return Pool_State;

   function Condition_Source
     (Id       : Source_Id;
      Session  : Session_Id;
      Sequence : U64;
      Data     : Raw_Window;
      Used     : Window_Byte_Count) return Digest_512;

   procedure Mix_Pool
     (Pool         : in out Pool_State;
      Source       : Source_Id;
      Contribution : Digest_512;
      Credit       : Credited_Bits);

   procedure Make_Frame
     (Pool            : in out Pool_State;
      Metrics         : Entropy_Metrics;
      Source_Bitmap   : U32;
      Healthy_Bitmap  : U32;
      Raw_Bytes       : U32;
      Accepted_Bytes  : U32;
      Gated_Bytes     : U32;
      Credited_Bits   : U32;
      Timestamp_Ms    : U64;
      Key             : CHVS_Key;
      Payload         : out CHVS_Payload;
      Frame           : out Wire_Frame);

   function Parse_Frame
     (Frame   : Wire_Frame;
      Key     : CHVS_Key;
      Payload : out CHVS_Payload) return Boolean;

   function Frame_Hash
     (Frame : Wire_Frame) return Digest_512;

   function Hex
     (Data : Byte_Array) return String;

   function Is_Private_Overlay_IP
     (IP : String) return Boolean;

end Chaos_CHVS;
