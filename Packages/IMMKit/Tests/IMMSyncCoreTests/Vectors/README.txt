Official Noise protocol test vectors
====================================

Format: noiseprotocol wiki "Test vectors" (JSON: protocol_name, init_/resp_ prologue, psks, static, ephemeral,
remote_static, handshake_hash (cacophony only), messages[{payload, ciphertext}]). Files are stored unmodified.

cacophony.txt
  Source   https://github.com/haskell-cryptography/cacophony  (vectors/cacophony.txt)
           raw: https://raw.githubusercontent.com/haskell-cryptography/cacophony/master/vectors/cacophony.txt
  Commit   18b7348c54fd61fcd0c220298883de0d09c8364d (last commit touching vectors/cacophony.txt), repo HEAD at download
           8ee9d41e34a1a596cfa3ab12aa4069ff87dc1247
  SHA-256  3bde7c09a6f349ee11c825c50fcc02649f8f02a47c857a459206b357f9386cae
  Vectors  944 (all suites); identical to snow's copy tests/vectors/cacophony.txt at 8ac60f51cfe3e010c84f0a454cc575ad9204fa12
  Licence  Unlicense (public domain)

snow.txt
  Source   https://github.com/mcginty/snow  (tests/vectors/snow.txt)
           raw: https://raw.githubusercontent.com/mcginty/snow/master/tests/vectors/snow.txt
  Commit   d00b360cc61a7fe519ce7539974dca4f36c4654a (last commit touching tests/vectors/snow.txt)
  SHA-256  69da433305fd045f6c9f01b656662a389d022688986fd39fbe7af009cd402fd3
  Vectors  408 (all suites)
  Licence  Apache-2.0 (snow), see https://github.com/mcginty/snow/blob/master/LICENSE-APACHE

Downloaded 2026-11-12. Spec: Noise Protocol Framework revision 34 (https://noiseprotocol.org/noise.html).

What the tests run (Tests/IMMSyncCoreTests/NoiseVectorTests.swift)
  Every vector whose protocol name is Noise_<fundamental pattern>[pskN[+pskM…]]_25519_ChaChaPoly_SHA256:
  36 in cacophony.txt and 28 in snow.txt, among them Noise_XXpsk3_25519_ChaChaPoly_SHA256, Noise_IK_25519_ChaChaPoly_SHA256,
  Noise_XX_…, Noise_NN_… and the one-way N, K, X patterns. Both roles are driven from the vector's keys (including the fixed
  ephemerals); every handshake message, every transport message and (cacophony) the handshake hash are compared byte for byte.
  Not run: other suites (AESGCM, BLAKE2, SHA512, 448), deferred patterns (NK1, X1N, …) and fallback patterns; IMM uses none of them.
