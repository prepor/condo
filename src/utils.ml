open! Core.Std

module Base64 = Utils_base64

let name_from_path path =
  try Filename.(path |> basename |> chop_extension)
  with Invalid_argument _ -> Filename.(path |> basename)

let random_str length =
  let buf = Bigbuffer.create length in
  let gen_char () = (match Random.int(26 + 26 + 10) with
    |  n when n < 26 -> int_of_char 'a' + n
    | n when n < 26 + 26 -> int_of_char 'A' + n - 26
    | n -> int_of_char '0' + n - 26 - 26)
                    |> char_of_int in
  for i = 0 to length do
    Bigbuffer.add_char buf (gen_char ())
  done;
  Bigbuffer.contents buf
