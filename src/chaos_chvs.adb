with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

package body Chaos_CHVS
  with SPARK_Mode => Off
is
   use Chaos_Types;
   use type Byte;
   use type U16;
   use type U32;
   use type U64;
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;
   use type Interfaces.C.unsigned;
   use type System.Address;

   package C renames Interfaces.C;
   package CS renames Interfaces.C.Strings;

   ---------------------------------------------------------------------------
   --  OpenSSL trusted cryptographic boundary
   ---------------------------------------------------------------------------

   function EVP_Q_digest
     (Libctx   : System.Address;
      Name     : CS.chars_ptr;
      Propq    : CS.chars_ptr;
      Data     : System.Address;
      Data_Len : C.size_t;
      Md       : System.Address;
      Md_Len   : access C.size_t) return C.int
   with
     Import,
     Convention    => C,
     External_Name => "EVP_Q_digest";

   function EVP_sha3_512 return System.Address
   with
     Import,
     Convention    => C,
     External_Name => "EVP_sha3_512";

   function HMAC
     (EVP_MD   : System.Address;
      Key      : System.Address;
      Key_Len  : C.int;
      Data     : System.Address;
      Data_Len : C.size_t;
      Md       : System.Address;
      Md_Len   : access C.unsigned) return System.Address
   with
     Import,
     Convention    => C,
     External_Name => "HMAC";

   function CRYPTO_memcmp
     (A   : System.Address;
      B   : System.Address;
      Len : C.size_t) return C.int
   with
     Import,
     Convention    => C,
     External_Name => "CRYPTO_memcmp";

   ---------------------------------------------------------------------------
   --  Helpers
   ---------------------------------------------------------------------------

   function Nibble
     (Ch : Character) return Integer
   is
   begin
      if Ch in '0' .. '9' then
         return Character'Pos (Ch) - Character'Pos ('0');
      elsif Ch in 'a' .. 'f' then
         return Character'Pos (Ch) - Character'Pos ('a') + 10;
      elsif Ch in 'A' .. 'F' then
         return Character'Pos (Ch) - Character'Pos ('A') + 10;
      else
         return -1;
      end if;
   end Nibble;

   function Decode_Key
     (Hex : String;
      Key : out CHVS_Key) return Boolean
   is
      Hi : Integer;
      Lo : Integer;
      P  : Natural;
   begin
      Key := (others => 0);

      if Hex'Length /= CHVS_Key_Bytes * 2 then
         return False;
      end if;

      for I in Key'Range loop
         P := Hex'First + (I - Key'First) * 2;

         Hi := Nibble (Hex (P));
         Lo := Nibble (Hex (P + 1));

         if Hi < 0 or else Lo < 0 then
            Key := (others => 0);
            return False;
         end if;

         Key (I) :=
           Byte (Hi * 16 + Lo);
      end loop;

      return True;
   end Decode_Key;

   function SHA3_512
     (Data : Byte_Array) return Digest_512
   is
      Output :
        aliased Digest_512 := (others => 0);

      Output_Length :
        aliased C.size_t :=
          C.size_t (SHA3_512_Bytes);

      Name :
        CS.chars_ptr := CS.New_String ("SHA3-512");

      Status :
        C.int;
   begin
      Status :=
        EVP_Q_digest
          (System.Null_Address,
           Name,
           CS.Null_Ptr,
           Data'Address,
           C.size_t (Data'Length),
           Output'Address,
           Output_Length'Access);

      CS.Free (Name);

      if Status /= 1
        or else Output_Length /= C.size_t (SHA3_512_Bytes)
      then
         raise Program_Error with
           "OpenSSL SHA3-512 failure";
      end if;

      return Output;
   end SHA3_512;

   function HMAC_SHA3_512
     (Key  : CHVS_Key;
      Data : Byte_Array) return Digest_512
   is
      Output :
        aliased Digest_512 := (others => 0);

      Output_Length :
        aliased C.unsigned := 0;

      Result :
        System.Address;
   begin
      Result :=
        HMAC
          (EVP_sha3_512,
           Key'Address,
           C.int (Key'Length),
           Data'Address,
           C.size_t (Data'Length),
           Output'Address,
           Output_Length'Access);

      if Result = System.Null_Address
        or else Output_Length /= C.unsigned (SHA3_512_Bytes)
      then
         raise Program_Error with
           "OpenSSL HMAC-SHA3-512 failure";
      end if;

      return Output;
   end HMAC_SHA3_512;

   procedure Put_U16
     (Buffer : in out Byte_Array;
      Pos    : in out Natural;
      Value  : U16)
   is
   begin
      Buffer (Pos) :=
        Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#);

      Buffer (Pos + 1) :=
        Byte (Value and 16#FF#);

      Pos := Pos + 2;
   end Put_U16;

   procedure Put_U32
     (Buffer : in out Byte_Array;
      Pos    : in out Natural;
      Value  : U32)
   is
   begin
      for Shift_Index in reverse 0 .. 3 loop
         Buffer (Pos) :=
           Byte
             (Interfaces.Shift_Right
                (Value, Shift_Index * 8) and 16#FF#);

         Pos := Pos + 1;
      end loop;
   end Put_U32;

   procedure Put_U64
     (Buffer : in out Byte_Array;
      Pos    : in out Natural;
      Value  : U64)
   is
   begin
      for Shift_Index in reverse 0 .. 7 loop
         Buffer (Pos) :=
           Byte
             (Interfaces.Shift_Right
                (Value, Shift_Index * 8) and 16#FF#);

         Pos := Pos + 1;
      end loop;
   end Put_U64;

   function Get_U16
     (Buffer : Byte_Array;
      Pos    : in out Natural) return U16
   is
      Result : U16;
   begin
      Result :=
        Interfaces.Shift_Left
          (U16 (Buffer (Pos)), 8)
        or U16 (Buffer (Pos + 1));

      Pos := Pos + 2;

      return Result;
   end Get_U16;

   function Get_U32
     (Buffer : Byte_Array;
      Pos    : in out Natural) return U32
   is
      Result : U32 := 0;
   begin
      for I in 1 .. 4 loop
         Result :=
           Interfaces.Shift_Left (Result, 8)
           or U32 (Buffer (Pos));

         Pos := Pos + 1;
      end loop;

      return Result;
   end Get_U32;

   function Get_U64
     (Buffer : Byte_Array;
      Pos    : in out Natural) return U64
   is
      Result : U64 := 0;
   begin
      for I in 1 .. 8 loop
         Result :=
           Interfaces.Shift_Left (Result, 8)
           or U64 (Buffer (Pos));

         Pos := Pos + 1;
      end loop;

      return Result;
   end Get_U64;

   function CRC32
     (Data : Byte_Array) return U32
   is
      Crc : U32 := 16#FFFF_FFFF#;
   begin
      for B of Data loop
         Crc := Crc xor U32 (B);

         for I in 1 .. 8 loop
            if (Crc and 1) /= 0 then
               Crc :=
                 Interfaces.Shift_Right (Crc, 1)
                 xor 16#EDB8_8320#;
            else
               Crc :=
                 Interfaces.Shift_Right (Crc, 1);
            end if;
         end loop;
      end loop;

      return not Crc;
   end CRC32;

   ---------------------------------------------------------------------------
   --  Pool
   ---------------------------------------------------------------------------

   function Initialize_Pool
     (Session : Session_Id) return Pool_State
   is
   begin
      return
        (Session             => Session,
         Digest              => (others => 0),
         Previous_Frame_Hash => (others => 0),
         Generation          => 0,
         Sequence            => 0);
   end Initialize_Pool;

   function Condition_Source
     (Id       : Source_Id;
      Session  : Session_Id;
      Sequence : U64;
      Data     : Raw_Window;
      Used     : Window_Byte_Count) return Digest_512
   is
      Domain :
        constant String :=
          "CHIRASU:CHAOS-SPARK:SOURCE:v1";

      Buffer :
        Byte_Array
          (1 ..
             Domain'Length
             + 1
             + Session_Id_Bytes
             + 8
             + 4
             + Used);

      Pos : Natural := 1;
   begin
      for Ch of Domain loop
         Buffer (Pos) := Byte (Character'Pos (Ch));
         Pos := Pos + 1;
      end loop;

      Buffer (Pos) :=
        Byte (Source_Id'Pos (Id));

      Pos := Pos + 1;

      for B of Session loop
         Buffer (Pos) := B;
         Pos := Pos + 1;
      end loop;

      Put_U64
        (Buffer,
         Pos,
         Sequence);

      Put_U32
        (Buffer,
         Pos,
         U32 (Used));

      for I in 1 .. Used loop
         Buffer (Pos) := Data (I);
         Pos := Pos + 1;
      end loop;

      return SHA3_512 (Buffer);
   end Condition_Source;

   procedure Mix_Pool
     (Pool         : in out Pool_State;
      Source       : Source_Id;
      Contribution : Digest_512;
      Credit       : Credited_Bits)
   is
      Domain :
        constant String :=
          "CHIRASU:CHAOS-SPARK:POOL:v1";

      Buffer :
        Byte_Array
          (1 ..
             Domain'Length
             + SHA3_512_Bytes
             + 1
             + SHA3_512_Bytes
             + 8
             + 4);

      Pos : Natural := 1;
   begin
      if Pool.Generation = U64'Last then
         raise Program_Error with
           "pool generation exhausted";
      end if;
      for Ch of Domain loop
         Buffer (Pos) := Byte (Character'Pos (Ch));
         Pos := Pos + 1;
      end loop;

      for B of Pool.Digest loop
         Buffer (Pos) := B;
         Pos := Pos + 1;
      end loop;

      Buffer (Pos) :=
        Byte (Source_Id'Pos (Source));

      Pos := Pos + 1;

      for B of Contribution loop
         Buffer (Pos) := B;
         Pos := Pos + 1;
      end loop;

      Put_U64
        (Buffer,
         Pos,
         Pool.Generation + 1);

      Put_U32
        (Buffer,
         Pos,
         U32 (Credit));

      Pool.Digest :=
        SHA3_512 (Buffer);

      if Pool.Generation < U64'Last then
         Pool.Generation :=
           Pool.Generation + 1;
      end if;
   end Mix_Pool;

   ---------------------------------------------------------------------------
   --  Wire framing
   ---------------------------------------------------------------------------

   function Serialize
     (Payload : CHVS_Payload;
      Key     : CHVS_Key) return Wire_Frame
   is
      Frame :
        Wire_Frame := (others => 0);

      Pos :
        Natural := 1;

      Check :
        U32;

      Tag :
        Digest_512;
   begin
      Frame (Pos) := Byte (Character'Pos ('C')); Pos := Pos + 1;
      Frame (Pos) := Byte (Character'Pos ('H')); Pos := Pos + 1;
      Frame (Pos) := Byte (Character'Pos ('V')); Pos := Pos + 1;
      Frame (Pos) := Byte (Character'Pos ('S')); Pos := Pos + 1;

      Frame (Pos) := Payload.Header.Version;
      Pos := Pos + 1;

      Put_U16 (Frame, Pos, Payload.Header.Flags);

      for B of Payload.Header.Session loop
         Frame (Pos) := B;
         Pos := Pos + 1;
      end loop;

      Put_U64 (Frame, Pos, Payload.Header.Sequence);
      Put_U64 (Frame, Pos, Payload.Header.Timestamp_Ms);

      Put_U32 (Frame, Pos, Payload.Header.Source_Bitmap);
      Put_U32 (Frame, Pos, Payload.Header.Healthy_Bitmap);

      Put_U32 (Frame, Pos, Payload.Header.Raw_Bytes);
      Put_U32 (Frame, Pos, Payload.Header.Accepted_Bytes);
      Put_U32 (Frame, Pos, Payload.Header.Gated_Bytes);

      Put_U16 (Frame, Pos, Payload.Header.Window_Bytes);

      Put_U16 (Frame, Pos, Payload.Header.Shannon_Milli);
      Put_U16 (Frame, Pos, Payload.Header.Min_Entropy_Milli);
      Put_U16 (Frame, Pos, Payload.Header.Markov_Milli);

      Put_U32
        (Frame,
         Pos,
         Payload.Header.Credited_Entropy_Bits);

      Put_U16
        (Frame,
         Pos,
         Payload.Header.Payload_Length);

      for B of Payload.Header.Previous_Frame_Hash loop
         Frame (Pos) := B;
         Pos := Pos + 1;
      end loop;

      for B of Payload.Header.Payload_Hash loop
         Frame (Pos) := B;
         Pos := Pos + 1;
      end loop;

      for B of Payload.Data loop
         Frame (Pos) := B;
         Pos := Pos + 1;
      end loop;

      Check :=
        CRC32 (Frame (1 .. Pos - 1));

      Put_U32
        (Frame,
         Pos,
         Check);

      Tag :=
        HMAC_SHA3_512
          (Key,
           Frame (1 .. Pos - 1));

      for B of Tag loop
         Frame (Pos) := B;
         Pos := Pos + 1;
      end loop;

      if Pos /= Wire_Frame_Bytes + 1 then
         raise Program_Error with
           "CHVS frame size mismatch";
      end if;

      return Frame;
   end Serialize;

   function Parse_Frame
     (Frame   : Wire_Frame;
      Key     : CHVS_Key;
      Payload : out CHVS_Payload) return Boolean
   is
      Pos :
        Natural := 1;

      Received_CRC :
        U32;

      Calculated_CRC :
        U32;

      Expected_Tag :
        aliased Digest_512;

      Received_Tag :
        aliased Digest_512;

      Payload_Hash :
        Digest_512;

      Tag_Start :
        constant Natural :=
          Wire_Frame_Bytes
          - SHA3_512_Bytes
          + 1;

      CRC_Start :
        constant Natural :=
          Tag_Start - 4;
   begin
      Payload :=
        (Header => (others => <>),
         Data   => (others => 0));

      if Character'Val (Frame (1)) /= 'C'
        or else Character'Val (Frame (2)) /= 'H'
        or else Character'Val (Frame (3)) /= 'V'
        or else Character'Val (Frame (4)) /= 'S'
      then
         return False;
      end if;

      Pos := 5;

      Payload.Header.Version := Frame (Pos);
      Pos := Pos + 1;

      if Payload.Header.Version /= CHVS_Version then
         return False;
      end if;

      Payload.Header.Flags := Get_U16 (Frame, Pos);

      for I in Payload.Header.Session'Range loop
         Payload.Header.Session (I) := Frame (Pos);
         Pos := Pos + 1;
      end loop;

      Payload.Header.Sequence := Get_U64 (Frame, Pos);
      Payload.Header.Timestamp_Ms := Get_U64 (Frame, Pos);

      Payload.Header.Source_Bitmap := Get_U32 (Frame, Pos);
      Payload.Header.Healthy_Bitmap := Get_U32 (Frame, Pos);

      Payload.Header.Raw_Bytes := Get_U32 (Frame, Pos);
      Payload.Header.Accepted_Bytes := Get_U32 (Frame, Pos);
      Payload.Header.Gated_Bytes := Get_U32 (Frame, Pos);

      Payload.Header.Window_Bytes := Get_U16 (Frame, Pos);

      Payload.Header.Shannon_Milli := Get_U16 (Frame, Pos);
      Payload.Header.Min_Entropy_Milli := Get_U16 (Frame, Pos);
      Payload.Header.Markov_Milli := Get_U16 (Frame, Pos);

      Payload.Header.Credited_Entropy_Bits :=
        Get_U32 (Frame, Pos);

      Payload.Header.Payload_Length :=
        Get_U16 (Frame, Pos);

      if Payload.Header.Payload_Length /=
        U16 (SHA3_512_Bytes)
      then
         return False;
      end if;

      for I in Payload.Header.Previous_Frame_Hash'Range loop
         Payload.Header.Previous_Frame_Hash (I) :=
           Frame (Pos);

         Pos := Pos + 1;
      end loop;

      for I in Payload.Header.Payload_Hash'Range loop
         Payload.Header.Payload_Hash (I) :=
           Frame (Pos);

         Pos := Pos + 1;
      end loop;

      for I in Payload.Data'Range loop
         Payload.Data (I) := Frame (Pos);
         Pos := Pos + 1;
      end loop;

      if Pos /= CRC_Start then
         return False;
      end if;

      Received_CRC :=
        Get_U32 (Frame, Pos);

      Calculated_CRC :=
        CRC32 (Frame (1 .. CRC_Start - 1));

      if Received_CRC /= Calculated_CRC then
         return False;
      end if;

      for I in Received_Tag'Range loop
         Received_Tag (I) :=
           Frame (Tag_Start + I - 1);
      end loop;

      Expected_Tag :=
        HMAC_SHA3_512
          (Key,
           Frame (1 .. Tag_Start - 1));

      if CRYPTO_memcmp
           (Expected_Tag'Address,
            Received_Tag'Address,
            C.size_t (SHA3_512_Bytes)) /= 0
      then
         return False;
      end if;

      Payload_Hash :=
        SHA3_512 (Payload.Data);

      if Payload_Hash /= Payload.Header.Payload_Hash then
         return False;
      end if;

      return True;
   exception
      when others =>
         return False;
   end Parse_Frame;

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
      Frame           : out Wire_Frame)
   is
      Domain :
        constant String :=
          "CHIRASU:CHAOS-SPARK:OUTPUT:v1";

      Seed :
        Byte_Array
          (1 ..
             Domain'Length
             + SHA3_512_Bytes
             + 8
             + 8);

      Pos :
        Natural := 1;

      Next_Sequence :
        U64;

      Minimum_Milli :
        Entropy_Milli;
   begin
      if Pool.Sequence = U64'Last then
         raise Program_Error with
           "CHVS sequence exhausted";
      end if;

      Next_Sequence :=
        Pool.Sequence + 1;

      for Ch of Domain loop
         Seed (Pos) := Byte (Character'Pos (Ch));
         Pos := Pos + 1;
      end loop;

      for B of Pool.Digest loop
         Seed (Pos) := B;
         Pos := Pos + 1;
      end loop;

      Put_U64
        (Seed,
         Pos,
         Pool.Generation);

      Put_U64
        (Seed,
         Pos,
         Next_Sequence);

      Payload.Data :=
        SHA3_512 (Seed);

      Minimum_Milli :=
        Metrics.MCV_Min_Milli;

      if Metrics.Markov_Milli < Minimum_Milli then
         Minimum_Milli := Metrics.Markov_Milli;
      end if;

      Payload.Header :=
        (Version                 => CHVS_Version,
         Flags                   => 0,
         Session                 => Pool.Session,
         Sequence                => Next_Sequence,
         Timestamp_Ms            => Timestamp_Ms,
         Source_Bitmap           => Source_Bitmap,
         Healthy_Bitmap          => Healthy_Bitmap,
         Raw_Bytes               => Raw_Bytes,
         Accepted_Bytes          => Accepted_Bytes,
         Gated_Bytes             => Gated_Bytes,
         Window_Bytes            => U16 (Raw_Window_Bytes),
         Shannon_Milli           => U16 (Metrics.Shannon_Milli),
         Min_Entropy_Milli       => U16 (Minimum_Milli),
         Markov_Milli            => U16 (Metrics.Markov_Milli),
         Credited_Entropy_Bits   => Credited_Bits,
         Payload_Length          => U16 (SHA3_512_Bytes),
         Previous_Frame_Hash     => Pool.Previous_Frame_Hash,
         Payload_Hash            => SHA3_512 (Payload.Data));

      Frame :=
        Serialize
          (Payload,
           Key);

      Pool.Sequence :=
        Next_Sequence;

      Pool.Previous_Frame_Hash :=
        Frame_Hash (Frame);
   end Make_Frame;

   function Frame_Hash
     (Frame : Wire_Frame) return Digest_512
   is
   begin
      return SHA3_512 (Frame);
   end Frame_Hash;

   function Hex
     (Data : Byte_Array) return String
   is
      Hex_Digits :
        constant String :=
          "0123456789abcdef";

      Result :
        String (1 .. Data'Length * 2);

      P :
        Natural := 1;

      V :
        Natural;
   begin
      for B of Data loop
         V := Natural (B);

         Result (P) :=
           Hex_Digits (V / 16 + 1);

         Result (P + 1) :=
           Hex_Digits (V mod 16 + 1);

         P := P + 2;
      end loop;

      return Result;
   end Hex;

   function Is_Private_Overlay_IP
     (IP : String) return Boolean
   is
      Parts :
        array (1 .. 4) of Integer := (others => -1);

      Part :
        Positive := 1;

      Value :
        Integer := 0;

      Have_Digit :
        Boolean := False;
   begin
      for Ch of IP loop
         if Ch in '0' .. '9' then
            Value :=
              Value * 10
              + Character'Pos (Ch)
              - Character'Pos ('0');

            if Value > 255 then
               return False;
            end if;

            Have_Digit := True;

         elsif Ch = '.' then
            if not Have_Digit or else Part >= 4 then
               return False;
            end if;

            Parts (Part) := Value;
            Part := Part + 1;
            Value := 0;
            Have_Digit := False;

         else
            return False;
         end if;
      end loop;

      if not Have_Digit or else Part /= 4 then
         return False;
      end if;

      Parts (4) := Value;

      return
        Parts (1) = 100
        and then Parts (2) in 64 .. 127;
   end Is_Private_Overlay_IP;

end Chaos_CHVS;
