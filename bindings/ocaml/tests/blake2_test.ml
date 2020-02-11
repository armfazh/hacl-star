open Test_utils

type 'a blake2_test =
  { name: string; plaintext: 'a; key: 'a; expected: 'a }

let tests = [
  {
    name = "Test 1";
    plaintext = Bigstring.of_string "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b";
    key = Bigstring.of_string "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f";
    expected = Bigstring.of_string "\xc8\xf6\x8e\x69\x6e\xd2\x82\x42\xbf\x99\x7f\x5b\x3b\x34\x95\x95\x08\xe4\x2d\x61\x38\x10\xf1\xe2\xa4\x35\xc9\x6e\xd2\xff\x56\x0c\x70\x22\xf3\x61\xa9\x23\x4b\x98\x37\xfe\xee\x90\xbf\x47\x92\x2e\xe0\xfd\x5f\x8d\xdf\x82\x37\x18\xd8\x6d\x1e\x16\xc6\x09\x00\x71"
  }
]

let test_to_bytes (v: Bigstring.t blake2_test) : Bytes.t blake2_test =
  { name = v.name ; plaintext = Bigstring.to_bytes v.plaintext ;
    key = Bigstring.to_bytes v.key ; expected = Bigstring.to_bytes v.expected }

let test (v: Bigstring.t blake2_test) n hash =
  let test_result = test_result (n ^ " " ^ v.name) in
  let output = Bigstring.create 64 in
  Bigstring.fill output '\x00';

  hash v.key v.plaintext output;
  if Bigstring.compare output v.expected = 0 then
    test_result Success ""
  else
    test_result Failure "Output mismatch"

let test_bytes (v: Bytes.t blake2_test) n hash =
  let test_result = test_result (n ^ " " ^ v.name) in
  let output = Bytes.create 64 in

  hash v.key v.plaintext output;
  if Bytes.compare output v.expected = 0 then
    test_result Success ""
  else
    test_result Failure "Output mismatch"


let _ =
  List.iter (fun v -> test v "Blake2b_32" Hacl.Blake2b_32.hash) tests;
  List.iter (fun v -> test v "Blake2b_256" Hacl.Blake2b_256.hash) tests;

  List.iter (fun v -> test_bytes v "Blake2b_32_bytes" Hacl.blake2b_32_bytes) (List.map test_to_bytes tests);
  List.iter (fun v -> test_bytes v "Blake2b_256_bytes" Hacl.blake2b_256_bytes) (List.map test_to_bytes tests)
